// Copyright (c) 2025 lws
// GIF (Graphics Interchange Format) encoder
//
// Writes single-frame GIF89a files:
//
//   - a global colour table with up to 256 entries
//   - an optional Graphic Control Extension that marks one index as
//     fully transparent
//   - LZW-compressed image data in sub-blocks
//
// The palette is built by collecting the exact colours of the image
// when it has 256 or fewer of them, and by median-cut quantisation
// otherwise.
//
// The LZW code-width rule is the one the GIF format uses: the width
// grows when the next free code no longer fits in the current width.
// It has to agree exactly with the decoder in `gif.mbt`, because the
// decoder is always one code behind the encoder.
//
// Specification: GIF89a.

//-----------------------------------------------------------------------------
// Colour histogram
//-----------------------------------------------------------------------------

///|
/// A hash of a packed RGB value or an LZW key.
///
/// The multiply is by a small odd constant so that it cannot overflow
/// a 32-bit integer, and the product is shifted down so that the low
/// bits of the result depend on the high bits of the input.
fn gif_hash(value : Int32) -> Int32 {
  let h = (value ^ (value >> 16)) & 0xFFFF
  ((h * 179) >> 4) & 0xFFFF
}

///|
/// A hash set of packed RGB values with their pixel counts.
///
/// The table is open-addressed with linear probing. `slots` keeps the
/// hash slots in insertion order, so the colours come out in the order
/// they first appear in the image. The table grows when it fills up, so
/// that every distinct colour of the image is counted.
priv struct RgbCounter {
  color : Array[Int32]
  count : Array[Int32]
  slots : Array[Int32]
  used : Array[Bool]
  mut size : Int32
  capacity : Int32
}

///|
fn RgbCounter::new() -> RgbCounter {
  {
    color: Array::make(1024, 0),
    count: Array::make(1024, 0),
    slots: Array::make(1024, 0),
    used: Array::make(1024, false),
    size: 0,
    capacity: 1024,
  }
}

///|
/// The hash slot a colour lives in, or -1 when it is not in the table.
fn RgbCounter::find(self : RgbCounter, rgb : Int32) -> Int32 {
  let mask = self.capacity - 1
  let mut idx = gif_hash(rgb) & mask
  let mut probes = 0
  while probes <= mask {
    if !self.used[idx] {
      return -1
    }
    if self.color[idx] == rgb {
      return idx
    }
    idx = (idx + 1) & mask
    probes = probes + 1
  }
  -1
}

///|
/// A counter with twice the capacity, holding the same colours.
fn RgbCounter::grown(self : RgbCounter) -> RgbCounter {
  let capacity = self.capacity * 2
  let color = Array::make(capacity, 0)
  let count = Array::make(capacity, 0)
  let slots = Array::make(capacity, 0)
  let used = Array::make(capacity, false)
  let mask = capacity - 1
  let mut i = 0
  while i < self.size {
    let old = self.slots[i]
    let rgb = self.color[old]
    let n = self.count[old]
    let mut idx = gif_hash(rgb) & mask
    while used[idx] {
      idx = (idx + 1) & mask
    }
    used[idx] = true
    color[idx] = rgb
    count[idx] = n
    slots[i] = idx
    i = i + 1
  }
  { color, count, slots, used, size: self.size, capacity, }
}

///|
/// Count one pixel of the given colour.
///
/// The counter is returned, because the table may have grown.
fn RgbCounter::add(self : RgbCounter, rgb : Int32) -> RgbCounter {
  let mut idx = self.find(rgb)
  if idx >= 0 {
    self.count[idx] = self.count[idx] + 1
    return self
  }
  if self.size * 2 >= self.capacity {
    let bigger = self.grown()
    return bigger.add(rgb)
  }
  let mask = self.capacity - 1
  idx = gif_hash(rgb) & mask
  while self.used[idx] {
    idx = (idx + 1) & mask
  }
  self.used[idx] = true
  self.color[idx] = rgb
  self.count[idx] = 1
  self.slots[self.size] = idx
  self.size = self.size + 1
  self
}

///|
/// The colours of an image, as unique RGB values with their counts.
priv struct ColorHistogram {
  rgb : Array[Int32]
  count : Array[Int32]
  size : Int32
}

///|
/// Build the colour histogram of the pixels that are not transparent.
fn gif_histogram(image : Image, alpha_threshold : Int32) -> ColorHistogram {
  let rgba = image.to_rgba8()
  let pixel_count = rgba.width * rgba.height
  let mut counter = RgbCounter::new()
  let mut i = 0
  while i < pixel_count {
    if rgba.data[i * 4 + 3].to_int() >= alpha_threshold {
      let r = rgba.data[i * 4].to_int()
      let g = rgba.data[i * 4 + 1].to_int()
      let b = rgba.data[i * 4 + 2].to_int()
      counter = counter.add((r << 16) | (g << 8) | b)
    }
    i = i + 1
  }
  // The colours in the order they first appear in the image.
  let rgb = []
  let count = []
  let mut k = 0
  while k < counter.size {
    let slot = counter.slots[k]
    rgb.push(counter.color[slot])
    count.push(counter.count[slot])
    k = k + 1
  }
  { rgb, count, size: rgb.length(), }
}

//-----------------------------------------------------------------------------
// Median cut
//-----------------------------------------------------------------------------

///|
/// One box of the median cut: a range of histogram entries.
priv struct ColorBox {
  lo : Int32
  hi : Int32
}

///|
/// The colour component of a packed RGB value.
fn gif_component(rgb : Int32, axis : Int32) -> Int32 {
  match axis {
    0 => (rgb >> 16) & 0xFF
    1 => (rgb >> 8) & 0xFF
    _ => rgb & 0xFF
  }
}

///|
/// The colour axis (0 = red, 1 = green, 2 = blue) along which a box
/// spans the widest range.
fn gif_box_axis(rgb : Array[Int32], box : ColorBox) -> Int32 {
  let span = [-1, -1, -1]
  let mut axis = 0
  let mut a = 0
  while a < 3 {
    let mut lo = 255
    let mut hi = 0
    let mut i = box.lo
    while i < box.hi {
      let c = gif_component(rgb[i], a)
      if c < lo {
        lo = c
      }
      if c > hi {
        hi = c
      }
      i = i + 1
    }
    span[a] = hi - lo
    if span[a] > span[axis] {
      axis = a
    }
    a = a + 1
  }
  axis
}

///|
/// Split a box in two at the point where half of its pixels have been
/// passed along the given axis. Returns the index the second box
/// starts at.
///
/// The entries of the box are ordered by the axis value first, so that
/// the split point can fall inside a group of equal values. Splitting
/// by value alone would leave one of the two boxes empty whenever a
/// single value carries more than half of the box's pixels, and the
/// quantisation would stop there with a palette that is far too small.
///
/// The colour array and the count array are partitioned together, so
/// that they stay aligned.
fn gif_split_box(
  rgb : Array[Int32],
  count : Array[Int32],
  box : ColorBox,
  axis : Int32,
) -> Int32 {
  let n = box.hi - box.lo
  if n < 2 {
    return box.lo
  }
  // A stable counting sort of the box's entries by the axis value.
  let bucket = Array::make(256, 0)
  let mut i = box.lo
  while i < box.hi {
    let c = gif_component(rgb[i], axis)
    bucket[c] = bucket[c] + 1
    i = i + 1
  }
  let cursor = Array::make(256, 0)
  let mut acc = 0
  let mut v = 0
  while v < 256 {
    cursor[v] = acc
    acc = acc + bucket[v]
    v = v + 1
  }
  let sorted = Array::make(n, 0)
  i = box.lo
  while i < box.hi {
    let c = gif_component(rgb[i], axis)
    sorted[cursor[c]] = i
    cursor[c] = cursor[c] + 1
    i = i + 1
  }

  // The split point: the first position where the cumulative pixel
  // count passes the halfway point. It always leaves at least one entry
  // on each side.
  let mut total = 0
  i = box.lo
  while i < box.hi {
    total = total + count[i]
    i = i + 1
  }
  let half = total / 2
  let mut pixels = count[sorted[0]]
  let mut pos = 1
  while pos < n - 1 {
    if pixels > half {
      break
    }
    pixels = pixels + count[sorted[pos]]
    pos = pos + 1
  }

  // Write the two halves back, in the sorted order.
  let new_rgb = Array::make(n, 0)
  let new_count = Array::make(n, 0)
  let mut j = 0
  while j < n {
    let src = sorted[j]
    new_rgb[j] = rgb[src]
    new_count[j] = count[src]
    j = j + 1
  }
  let mut k = box.lo
  j = 0
  while j < n {
    rgb[k] = new_rgb[j]
    count[k] = new_count[j]
    k = k + 1
    j = j + 1
  }
  box.lo + pos
}

///|
/// Median-cut quantisation: repeatedly split the box with the widest
/// colour range until there are `target` boxes, then use each box's
/// count-weighted average colour as one palette entry.
fn gif_median_cut(hist : ColorHistogram, target : Int32) -> Array[Int32] {
  let rgb = hist.rgb
  let count = hist.count
  let n = rgb.length()
  let out : Array[Int32] = []
  if n == 0 {
    return out
  }
  let mut boxes : Array[ColorBox] = [{ lo: 0, hi: n, }]
  while boxes.length() < target {
    // Pick the box with the largest colour range.
    let mut best = -1
    let mut best_range = 0
    let mut best_axis = 0
    let mut bi = 0
    while bi < boxes.length() {
      let box = boxes[bi]
      let axis = gif_box_axis(rgb, box)
      let mut lo = 255
      let mut hi = 0
      let mut i = box.lo
      while i < box.hi {
        let c = gif_component(rgb[i], axis)
        if c < lo {
          lo = c
        }
        if c > hi {
          hi = c
        }
        i = i + 1
      }
      let range = hi - lo
      if range > best_range {
        best_range = range
        best = bi
        best_axis = axis
      }
      bi = bi + 1
    }
    if best < 0 || best_range <= 0 {
      break // nothing left to split
    }
    let box = boxes[best]
    let split = gif_split_box(rgb, count, box, best_axis)
    if split <= box.lo || split >= box.hi {
      break // the split would be degenerate
    }
    let next : Array[ColorBox] = []
    let mut k = 0
    while k < boxes.length() {
      if k == best {
        next.push({ lo: box.lo, hi: split, })
        next.push({ lo: split, hi: box.hi, })
      } else {
        next.push(boxes[k])
      }
      k = k + 1
    }
    boxes = next
  }
  // Each box becomes one palette entry: the count-weighted average.
  let mut i = 0
  while i < boxes.length() {
    let box = boxes[i]
    let mut r = 0
    let mut g = 0
    let mut b = 0
    let mut total = 0
    let mut k = box.lo
    while k < box.hi {
      let c = count[k]
      r = r + gif_component(rgb[k], 0) * c
      g = g + gif_component(rgb[k], 1) * c
      b = b + gif_component(rgb[k], 2) * c
      total = total + c
      k = k + 1
    }
    if total > 0 {
      out.push(
        (((r / total) << 16) | ((g / total) << 8) | (b / total)) & 0xFFFFFF,
      )
    } else {
      out.push(0)
    }
    i = i + 1
  }
  out
}

//-----------------------------------------------------------------------------
// Palette lookup
//-----------------------------------------------------------------------------

///|
/// A direct-mapped cache from a packed RGB value to its palette index.
priv struct PaletteCache {
  key : Array[Int32]
  value : Array[Int32]
}

///|
fn PaletteCache::new() -> PaletteCache {
  { key: Array::make(4096, -1), value: Array::make(4096, 0), }
}

///|
/// The index of the palette entry closest to a packed RGB value.
fn gif_palette_lookup(
  cache : PaletteCache,
  palette : Array[Int32],
  rgb : Int32,
) -> Int32 {
  let slot = gif_hash(rgb) & 4095
  if cache.key[slot] == rgb {
    return cache.value[slot]
  }
  let r = gif_component(rgb, 0)
  let g = gif_component(rgb, 1)
  let b = gif_component(rgb, 2)
  let mut best = 0
  let mut best_dist = -1
  let mut i = 0
  while i < palette.length() {
    let p = palette[i]
    let dr = r - gif_component(p, 0)
    let dg = g - gif_component(p, 1)
    let db = b - gif_component(p, 2)
    let dist = dr * dr + dg * dg + db * db
    if best_dist < 0 || dist < best_dist {
      best_dist = dist
      best = i
      if dist == 0 {
        break
      }
    }
    i = i + 1
  }
  cache.key[slot] = rgb
  cache.value[slot] = best
  best
}

//-----------------------------------------------------------------------------
// LZW compressor
//-----------------------------------------------------------------------------

///|
/// Packs LZW codes into bytes, least-significant bit first.
priv struct GifBitWriter {
  buf : Array[Byte]
  mut bit_buf : Int32
  mut bit_count : Int32
}

///|
fn GifBitWriter::new() -> GifBitWriter {
  { buf: [], bit_buf: 0, bit_count: 0, }
}

///|
/// Append a code of `width` bits.
fn GifBitWriter::write_code(
  self : GifBitWriter,
  code : Int32,
  width : Int32,
) -> Unit {
  self.bit_buf = self.bit_buf | (code << self.bit_count)
  self.bit_count = self.bit_count + width
  while self.bit_count >= 8 {
    self.buf.push((self.bit_buf & 0xFF).to_byte())
    self.bit_buf = self.bit_buf >> 8
    self.bit_count = self.bit_count - 8
  }
}

///|
/// Flush the partial byte.
fn GifBitWriter::flush(self : GifBitWriter) -> Unit {
  if self.bit_count > 0 {
    self.buf.push((self.bit_buf & 0xFF).to_byte())
    self.bit_buf = 0
    self.bit_count = 0
  }
}

///|
/// A hash table from (prefix code, suffix) to a code.
priv struct LzwTable {
  keys : Array[Int32]
  codes : Array[Int32]
  used : Array[Bool]
}

///|
fn LzwTable::new() -> LzwTable {
  {
    keys: Array::make(8192, 0),
    codes: Array::make(8192, 0),
    used: Array::make(8192, false),
  }
}

///|
/// Look up the code for a (prefix, suffix) pair, or -1.
fn LzwTable::get(self : LzwTable, prefix : Int32, suffix : Int32) -> Int32 {
  let key = prefix * 256 + suffix
  let mut idx = gif_hash(key) & 8191
  let mut probes = 0
  while probes < 8192 {
    if !self.used[idx] {
      return -1
    }
    if self.keys[idx] == key {
      return self.codes[idx]
    }
    idx = (idx + 1) & 8191
    probes = probes + 1
  }
  -1
}

///|
/// Store a code for a (prefix, suffix) pair.
fn LzwTable::put(
  self : LzwTable,
  prefix : Int32,
  suffix : Int32,
  code : Int32,
) -> Unit {
  let key = prefix * 256 + suffix
  let mut idx = gif_hash(key) & 8191
  let mut probes = 0
  while probes < 8192 {
    if !self.used[idx] {
      self.used[idx] = true
      self.keys[idx] = key
      self.codes[idx] = code
      return
    }
    if self.keys[idx] == key {
      self.codes[idx] = code
      return
    }
    idx = (idx + 1) & 8191
    probes = probes + 1
  }
}

///|
/// Compress a sequence of palette indices with GIF's LZW.
///
/// The code width grows when the next free code no longer fits in the
/// current width, which is what the decoder in `gif.mbt` expects.
fn gif_lzw_compress(
  indices : Array[Int32],
  min_code_size : Int32,
) -> Array[Byte] {
  let writer = GifBitWriter::new()
  let clear_code = 1 << min_code_size
  let eoi_code = clear_code + 1

  let mut code_size = min_code_size + 1
  let mut next_code = eoi_code + 1
  let table = LzwTable::new()
  writer.write_code(clear_code, code_size)

  if indices.length() == 0 {
    writer.write_code(eoi_code, code_size)
    writer.flush()
    return writer.buf
  }

  let mut prefix = indices[0]
  let mut i = 1
  while i < indices.length() {
    let suffix = indices[i]
    let found = table.get(prefix, suffix)
    if found >= 0 {
      prefix = found
    } else {
      writer.write_code(prefix, code_size)
      if next_code < 4096 {
        table.put(prefix, suffix, next_code)
        next_code = next_code + 1
        // The code width has to grow when the next code to be assigned
        // no longer fits in the current width. The decoder grows its
        // width one code later than the encoder adds the entry, so the
        // two conditions differ by one: the decoder is always one code
        // behind the encoder.
        if next_code > 1 << code_size && code_size < 12 {
          code_size = code_size + 1
        }
      } else {
        // The table is full: start over with a clear code.
        writer.write_code(clear_code, code_size)
        next_code = eoi_code + 1
        code_size = min_code_size + 1
      }
      prefix = suffix
    }
    i = i + 1
  }
  writer.write_code(prefix, code_size)
  writer.write_code(eoi_code, code_size)
  writer.flush()
  writer.buf
}

//-----------------------------------------------------------------------------
// GIF encoder
//-----------------------------------------------------------------------------

///|
/// Pixels with an alpha value below this become fully transparent.
const GIF_ALPHA_THRESHOLD : Int32 = 128

///|
/// Encode an image as a single-frame GIF89a file.
///
/// The palette holds the image's exact colours when it has few enough of
/// them (256, or 255 when the image has transparency), and a median-cut
/// approximation of them otherwise. Pixels whose alpha is below 128
/// become transparent, using one reserved palette entry.
///
/// # Errors
///
/// Raises `Failure` if the image has zero width or height.
pub fn encode_gif(image : Image) -> Bytes raise Failure {
  if image.width <= 0 || image.height <= 0 {
    raise Failure::Failure(
      "GIF encode: image dimensions must be positive, got \{image.width}x\{image.height}",
    )
  }

  let rgba = image.to_rgba8()
  let pixel_count = rgba.width * rgba.height

  // Does the image need a transparent entry?
  let mut has_transparency = false
  let mut i = 0
  while i < pixel_count {
    if rgba.data[i * 4 + 3].to_int() < GIF_ALPHA_THRESHOLD {
      has_transparency = true
      break
    }
    i = i + 1
  }

  let hist = gif_histogram(image, GIF_ALPHA_THRESHOLD)
  let max_colors = if has_transparency { 255 } else { 256 }
  let palette = if hist.size <= max_colors {
    // Few enough colours to keep them all.
    let colors : Array[Int32] = []
    let mut k = 0
    while k < hist.size {
      colors.push(hist.rgb[k])
      k = k + 1
    }
    colors
  } else {
    gif_median_cut(hist, max_colors)
  }

  // The palette has one slot per colour, plus one more for the
  // transparent entry when the image has transparency.
  //
  // The LZW code size has to cover every slot: the clear code is
  // 1 << bits, so a palette index must never reach it, or the decoder
  // reads the clear code as a pixel and the stream falls out of step.
  let slot_count = palette.length() + (if has_transparency { 1 } else { 0 })
  let mut bits = 2
  while 1 << bits < slot_count {
    bits = bits + 1
  }
  if bits > 8 {
    bits = 8
  }
  let min_code_size = bits
  let table_size = 1 << bits

  // Map every pixel to a palette index.
  let cache = PaletteCache::new()
  let indices = Array::make(pixel_count, 0)
  let transparent_index = palette.length()
  i = 0
  while i < pixel_count {
    if rgba.data[i * 4 + 3].to_int() < GIF_ALPHA_THRESHOLD {
      indices[i] = transparent_index
    } else {
      let packed = (rgba.data[i * 4].to_int() << 16) |
        (rgba.data[i * 4 + 1].to_int() << 8) |
        rgba.data[i * 4 + 2].to_int()
      indices[i] = gif_palette_lookup(cache, palette, packed)
    }
    i = i + 1
  }

  // --- Assemble the file ---
  let out : Array[Byte] = []
  // Header and logical screen descriptor.
  out.push(b'G')
  out.push(b'I')
  out.push(b'F')
  out.push(b'8')
  out.push(b'9')
  out.push(b'a')
  out.push((image.width & 0xFF).to_byte())
  out.push(((image.width >> 8) & 0xFF).to_byte())
  out.push((image.height & 0xFF).to_byte())
  out.push(((image.height >> 8) & 0xFF).to_byte())
  // Global colour table flag, colour resolution and the table size.
  let size_bits = min_code_size - 1
  out.push((0x80 | (size_bits << 4) | size_bits).to_byte())
  out.push(b'\x00') // background colour index
  out.push(b'\x00') // pixel aspect ratio
  // The global colour table.
  let mut k = 0
  while k < table_size {
    if k < palette.length() {
      let p = palette[k]
      out.push(gif_component(p, 0).to_byte())
      out.push(gif_component(p, 1).to_byte())
      out.push(gif_component(p, 2).to_byte())
    } else {
      out.push(b'\x00')
      out.push(b'\x00')
      out.push(b'\x00')
    }
    k = k + 1
  }

  // Graphic Control Extension, when there is transparency.
  if has_transparency {
    out.push(b'\x21')
    out.push(b'\xF9')
    out.push(b'\x04')
    // Disposal method 1 ("do not dispose") and the transparency flag.
    out.push(b'\x09')
    out.push(b'\x00') // delay, low byte
    out.push(b'\x00') // delay, high byte
    out.push(transparent_index.to_byte())
    out.push(b'\x00') // block terminator
  }

  // Image descriptor.
  out.push(b'\x2C')
  out.push(b'\x00') // left, low
  out.push(b'\x00') // left, high
  out.push(b'\x00') // top, low
  out.push(b'\x00') // top, high
  out.push((image.width & 0xFF).to_byte())
  out.push(((image.width >> 8) & 0xFF).to_byte())
  out.push((image.height & 0xFF).to_byte())
  out.push(((image.height >> 8) & 0xFF).to_byte())
  out.push(b'\x00') // no local colour table, not interlaced

  // LZW minimum code size and the compressed data in sub-blocks.
  out.push(min_code_size.to_byte())
  let compressed = gif_lzw_compress(indices, min_code_size)
  let mut pos = 0
  while pos < compressed.length() {
    let n = if compressed.length() - pos < 255 {
      compressed.length() - pos
    } else {
      255
    }
    out.push(n.to_byte())
    let mut j = 0
    while j < n {
      out.push(compressed[pos + j])
      j = j + 1
    }
    pos = pos + n
  }
  out.push(b'\x00') // block terminator

  // Trailer.
  out.push(b'\x3B')
  Bytes::from_array(out)
}
