// Copyright (c) 2025 lws
// TIFF encoder for MoonBit.
//
// Writes an uncompressed, little-endian, single-strip TIFF:
//
//   Header (8 bytes)
//     char[2]  byte order    // "II"
//     uint16   magic         // 42
//     uint32   ifd_offset
//
//   IFD
//     uint16   entry_count
//     entry[entry_count]      // 12 bytes each, sorted by tag
//     uint32   next_ifd       // 0
//
//   IFD entry
//     uint16   tag
//     uint16   type           // 3 = SHORT, 4 = LONG
//     uint32   count
//     uint32   value          // the value, or an offset to it
//
//   pixel data
//     the strip, one row after another, top to bottom
//
// The format is deliberately the simplest one the format allows:
// no compression, one strip, chunky (interleaved) samples. Every
// reader understands it, and the package's own decoder handles it
// directly.
//
// The decoder in tiff.mbt accepts more than this -- LZW, Deflate and
// PackBits strips, a horizontal predictor and multiple strips -- but the
// writer emits the simplest form on purpose.
//
// This is a from-scratch implementation: the package has no external
// runtime dependencies, so neither libtiff nor a binding to it can be
// used.

//-----------------------------------------------------------------------------
// Tag and type constants
//-----------------------------------------------------------------------------

///|
const TIFF_TAG_WIDTH : Int32 = 256

///|
const TIFF_TAG_LENGTH : Int32 = 257

///|
const TIFF_TAG_BITS_PER_SAMPLE : Int32 = 258

///|
const TIFF_TAG_COMPRESSION : Int32 = 259

///|
const TIFF_TAG_PHOTOMETRIC : Int32 = 262

///|
const TIFF_TAG_STRIP_OFFSETS : Int32 = 273

///|
const TIFF_TAG_SAMPLES_PER_PIXEL : Int32 = 277

///|
const TIFF_TAG_ROWS_PER_STRIP : Int32 = 278

///|
const TIFF_TAG_STRIP_BYTE_COUNTS : Int32 = 279

///|
const TIFF_TAG_PLANAR_CONFIGURATION : Int32 = 284

///|
const TIFF_TAG_PREDICTOR : Int32 = 317

///|
const TIFF_TAG_EXTRA_SAMPLES : Int32 = 338

///|
const TIFF_TYPE_SHORT : Int32 = 3

///|
const TIFF_TYPE_LONG : Int32 = 4

///|
const TIFF_PHOTOMETRIC_BLACK_IS_ZERO : Int32 = 1

///|
const TIFF_PHOTOMETRIC_RGB : Int32 = 2

///|
/// One IFD entry, before it is serialised.
priv struct TiffEntry {
  tag : Int32
  typ : Int32
  count : Int32
  /// The value of the entry, when it fits into the four byte slot.
  value : Int32
  /// The values of an entry that needs more than four bytes.  Empty when
  /// the entry holds a single value.
  values : Array[Int32]
}

///|
/// Write a 16-bit little-endian value.
fn tiff_put_u16(buf : Array[Byte], value : Int32) -> Unit {
  buf.push((value & 0xFF).to_byte())
  buf.push(((value >> 8) & 0xFF).to_byte())
}

///|
/// Write a 32-bit little-endian value.
fn tiff_put_u32(buf : Array[Byte], value : Int32) -> Unit {
  buf.push((value & 0xFF).to_byte())
  buf.push(((value >> 8) & 0xFF).to_byte())
  buf.push(((value >> 16) & 0xFF).to_byte())
  buf.push(((value >> 24) & 0xFF).to_byte())
}

//-----------------------------------------------------------------------------
// LZW compression
//-----------------------------------------------------------------------------

///|
/// A bit writer that packs most significant bit first, which is what the
/// TIFF dialect of LZW uses.
priv struct TiffBitWriter {
  buf : Array[Byte]
  mut acc : Int32
  mut nbits : Int32
}

///|
fn TiffBitWriter::new() -> TiffBitWriter {
  { buf: [], acc: 0, nbits: 0, }
}

///|
fn TiffBitWriter::put(
  self : TiffBitWriter,
  code : Int32,
  width : Int32,
) -> Unit {
  self.acc = (self.acc << width) | (code & ((1 << width) - 1))
  self.nbits = self.nbits + width
  while self.nbits >= 8 {
    self.buf.push(((self.acc >> (self.nbits - 8)) & 0xFF).to_byte())
    self.nbits = self.nbits - 8
    self.acc = self.acc & ((1 << self.nbits) - 1)
  }
}

///|
fn TiffBitWriter::flush(self : TiffBitWriter) -> Unit {
  if self.nbits > 0 {
    self.buf.push((self.acc & 0xFF).to_byte())
    self.acc = 0
    self.nbits = 0
  }
}

///|
/// A hash table from a (prefix code, byte) pair to a code.
///
/// The table is open addressed with linear probing.  The prefix of a code
/// and the byte that follows it form the key, so the table holds at most
/// 4094 entries and 8192 slots keep it half full.
priv struct TiffLzwTable {
  keys : Array[Int32]
  codes : Array[Int32]
  used : Array[Bool]
}

///|
fn TiffLzwTable::new() -> TiffLzwTable {
  {
    keys: Array::make(8192, 0),
    codes: Array::make(8192, 0),
    used: Array::make(8192, false),
  }
}

///|
fn tiff_lzw_hash(key : Int32) -> Int32 {
  let h = (key ^ (key >> 16)) & 0xFFFF
  ((h * 179) >> 4) & 0xFFFF
}

///|
fn TiffLzwTable::get(self : TiffLzwTable, key : Int32) -> Int32 {
  let mut idx = tiff_lzw_hash(key) & 8191
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
fn TiffLzwTable::put(self : TiffLzwTable, key : Int32, code : Int32) -> Unit {
  let mut idx = tiff_lzw_hash(key) & 8191
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
fn TiffLzwTable::clear(self : TiffLzwTable) -> Unit {
  for i = 0; i < self.used.length(); i = i + 1 {
    self.used[i] = false
  }
}

///|
/// Compress a strip with the TIFF dialect of LZW.
///
/// The codes are packed most significant bit first, start at nine bits and
/// grow to twelve.  256 is the clear code and 257 the end-of-information
/// code; the first free code is 258.  The dictionary maps a (prefix code,
/// byte) pair to a code, and it is reset with a clear code when the code
/// space fills up.
fn tiff_lzw_encode(src : Bytes) -> Bytes {
  let bw = TiffBitWriter::new()
  let table = TiffLzwTable::new()
  let mut width = 9
  let mut next = 258
  bw.put(256, width)
  if src.length() > 0 {
    let mut prefix = src[0].to_int()
    let mut i = 1
    while i < src.length() {
      let c = src[i].to_int()
      let key = prefix * 256 + c
      let found = table.get(key)
      if found >= 0 {
        prefix = found
      } else {
        bw.put(prefix, width)
        if next < 4094 {
          table.put(key, next)
          next = next + 1
          // The decoder adds its entry one code later, so it widens one
          // code before the table fills the width.
          if next > (1 << width) - 1 && width < 12 {
            width = width + 1
          }
        } else {
          // The table is full: reset it with a clear code.
          bw.put(256, width)
          table.clear()
          next = 258
          width = 9
        }
        prefix = c
      }
      i = i + 1
    }
    bw.put(prefix, width)
  }
  bw.put(257, width)
  bw.flush()
  Bytes::from_array(bw.buf)
}

///|
/// Apply the horizontal differencing predictor (TIFF tag 317 = 2).
///
/// Every sample is replaced by the difference to the sample `samples`
/// positions before it, which the decoder adds back.
fn tiff_apply_predictor(
  data : Array[Byte],
  row_bytes : Int32,
  samples : Int32,
) -> Unit {
  let rows = data.length() / row_bytes
  let mut r = 0
  while r < rows {
    let base = r * row_bytes
    let mut i = row_bytes - 1
    while i >= samples {
      let v = (data[base + i].to_int() - data[base + i - samples].to_int()) &
        0xFF
      data[base + i] = v.to_byte()
      i = i - 1
    }
    r = r + 1
  }
}

///|
/// Encode an image as a TIFF file.
///
/// Greyscale images are written as a single 8-bit channel; colour
/// images as RGB, with the alpha channel kept as a fourth sample when
/// the source has one. A source with a grey alpha channel is expanded
/// to grey + alpha, which loses nothing.
///
/// The samples are written with the horizontal differencing predictor and
/// compressed with LZW, in strips of about 8 KiB, which is what keeps the
/// file close in size to what the reference implementation writes.
///
/// # Errors
///
/// Raises `Failure` if the image has zero width or height.
pub fn encode_tiff(image : Image) -> Bytes raise Failure {
  if image.width <= 0 || image.height <= 0 {
    raise Failure::Failure(
      "TIFF encode: image dimensions must be positive, got \{image.width}x\{image.height}",
    )
  }

  let rgba = image.to_rgba8()
  let width = rgba.width
  let height = rgba.height
  let pixel_count = width * height

  // Decide the colour layout. A greyscale image keeps a single
  // channel, an RGB image keeps three, and anything with an alpha
  // channel keeps four. A grey source with alpha is expanded to grey
  // + alpha, which loses nothing.
  let samples = match image.format {
    PixelFormat::Gray8 => 1
    PixelFormat::GrayA8 => 4
    PixelFormat::RGB8 => 3
    PixelFormat::RGBA8 => 4
  }
  let grayscale = samples == 1
  let has_alpha = samples == 4
  let photometric = if grayscale {
    TIFF_PHOTOMETRIC_BLACK_IS_ZERO
  } else {
    TIFF_PHOTOMETRIC_RGB
  }

  // --- The pixel data ---
  let raw : Array[Byte] = []
  if grayscale {
    let mut i = 0
    while i < pixel_count {
      raw.push(rgba.data[i * 4])
      i = i + 1
    }
  } else if samples == 3 {
    let mut i = 0
    while i < pixel_count {
      raw.push(rgba.data[i * 4]) // R
      raw.push(rgba.data[i * 4 + 1]) // G
      raw.push(rgba.data[i * 4 + 2]) // B
      i = i + 1
    }
  } else {
    let mut i = 0
    while i < pixel_count {
      raw.push(rgba.data[i * 4]) // R
      raw.push(rgba.data[i * 4 + 1]) // G
      raw.push(rgba.data[i * 4 + 2]) // B
      raw.push(rgba.data[i * 4 + 3]) // A
      i = i + 1
    }
  }

  // --- The strips ---
  // The strips hold about 8 KiB of raw samples each.
  let row_bytes = width * samples
  let mut rows_per_strip = 8192 / row_bytes
  if rows_per_strip < 1 {
    rows_per_strip = 1
  }
  if rows_per_strip > height {
    rows_per_strip = height
  }
  let nstrips = (height + rows_per_strip - 1) / rows_per_strip
  let strips : Array[Bytes] = []
  let strip_offsets : Array[Int32] = []
  let strip_counts : Array[Int32] = []
  let mut s = 0
  while s < nstrips {
    let first_row = s * rows_per_strip
    let rows = if first_row + rows_per_strip > height {
      height - first_row
    } else {
      rows_per_strip
    }
    let chunk : Array[Byte] = []
    let mut p = first_row * row_bytes
    let end = p + rows * row_bytes
    while p < end {
      chunk.push(raw[p])
      p = p + 1
    }
    tiff_apply_predictor(chunk, row_bytes, samples)
    let compressed = tiff_lzw_encode(Bytes::from_array(chunk))
    strip_offsets.push(0) // filled in below
    strip_counts.push(compressed.length())
    strips.push(compressed)
    s = s + 1
  }

  // --- The IFD ---
  // The entries have to be sorted by tag.  The entries that hold more than
  // one value do not fit into the four byte slot of the entry, so their
  // values live outside the IFD and the entry holds their offset.
  let entry_count = if has_alpha { 12 } else { 11 }
  let mut data_len = 0
  let mut i = 0
  while i < strips.length() {
    let n = strips[i].length()
    data_len = data_len + n + (n & 1)
    i = i + 1
  }
  let ifd_offset = 8 + data_len
  let ifd_size = 2 + entry_count * 12 + 4
  let extra_base = ifd_offset + ifd_size

  // The out-of-line values, in the order the entries need them.
  let mut extra_pos = extra_base
  // BitsPerSample: one value per sample.
  let bits_values : Array[Int32] = []
  let mut b = 0
  while b < samples {
    bits_values.push(8)
    b = b + 1
  }
  let bits_offset = if samples > 1 {
    let off = extra_pos
    extra_pos = extra_pos + samples * 2
    off
  } else {
    0
  }
  // StripOffsets and StripByteCounts: one value per strip.
  let offsets_offset = if nstrips > 1 {
    let off = extra_pos
    extra_pos = extra_pos + nstrips * 4
    off
  } else {
    0
  }
  let counts_offset = if nstrips > 1 {
    let off = extra_pos
    extra_pos = extra_pos + nstrips * 4
    off
  } else {
    0
  }

  let entries : Array[TiffEntry] = []
  entries.push({
    tag: TIFF_TAG_WIDTH,
    typ: TIFF_TYPE_LONG,
    count: 1,
    value: width,
    values: [],
  })
  entries.push({
    tag: TIFF_TAG_LENGTH,
    typ: TIFF_TYPE_LONG,
    count: 1,
    value: height,
    values: [],
  })
  entries.push({
    tag: TIFF_TAG_BITS_PER_SAMPLE,
    typ: TIFF_TYPE_SHORT,
    count: samples,
    value: if samples > 1 {
      bits_offset
    } else {
      8
    },
    values: bits_values,
  })
  entries.push({
    tag: TIFF_TAG_COMPRESSION,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: 5, // LZW
    values: [],
  })
  entries.push({
    tag: TIFF_TAG_PHOTOMETRIC,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: photometric,
    values: [],
  })
  entries.push({
    tag: TIFF_TAG_STRIP_OFFSETS,
    typ: TIFF_TYPE_LONG,
    count: nstrips,
    // The strip data sits between the header and the IFD, so the first
    // strip always starts at offset 8.
    value: if nstrips > 1 {
      offsets_offset
    } else {
      8
    },
    values: strip_offsets,
  })
  entries.push({
    tag: TIFF_TAG_SAMPLES_PER_PIXEL,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: samples,
    values: [],
  })
  entries.push({
    tag: TIFF_TAG_ROWS_PER_STRIP,
    typ: TIFF_TYPE_LONG,
    count: 1,
    value: rows_per_strip,
    values: [],
  })
  entries.push({
    tag: TIFF_TAG_STRIP_BYTE_COUNTS,
    typ: TIFF_TYPE_LONG,
    count: nstrips,
    value: if nstrips > 1 {
      counts_offset
    } else {
      strip_counts[0]
    },
    values: strip_counts,
  })
  entries.push({
    tag: TIFF_TAG_PLANAR_CONFIGURATION,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: 1, // chunky
    values: [],
  })
  entries.push({
    tag: TIFF_TAG_PREDICTOR,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: 2, // horizontal differencing
    values: [],
  })
  if has_alpha {
    // ExtraSamples: 2 means "unassociated alpha".
    entries.push({
      tag: TIFF_TAG_EXTRA_SAMPLES,
      typ: TIFF_TYPE_SHORT,
      count: 1,
      value: 2,
      values: [],
    })
  }

  // --- The file ---
  let out : Array[Byte] = []

  // Header
  out.push(b'I')
  out.push(b'I')
  tiff_put_u16(out, 42)
  tiff_put_u32(out, ifd_offset)

  // The strip data, with every strip padded to an even length.
  let mut pos = 8
  let mut k = 0
  while k < strips.length() {
    strip_offsets[k] = pos
    let st = strips[k]
    let mut p = 0
    while p < st.length() {
      out.push(st[p])
      p = p + 1
    }
    if (st.length() & 1) == 1 {
      out.push(b'\x00')
    }
    pos = pos + st.length() + (st.length() & 1)
    k = k + 1
  }

  // IFD
  tiff_put_u16(out, entry_count)
  let mut i = 0
  while i < entry_count {
    let e = entries[i]
    tiff_put_u16(out, e.tag)
    tiff_put_u16(out, e.typ)
    tiff_put_u32(out, e.count)
    if e.typ == TIFF_TYPE_SHORT && e.count == 1 {
      // A single SHORT fits in the first two bytes of the value field.
      tiff_put_u16(out, e.value)
      out.push(b'\x00')
      out.push(b'\x00')
    } else {
      tiff_put_u32(out, e.value)
    }
    i = i + 1
  }
  tiff_put_u32(out, 0) // no next IFD

  // The out-of-line values.
  if samples > 1 {
    let mut s2 = 0
    while s2 < bits_values.length() {
      tiff_put_u16(out, bits_values[s2])
      s2 = s2 + 1
    }
  }
  if nstrips > 1 {
    let mut s2 = 0
    while s2 < strip_offsets.length() {
      tiff_put_u32(out, strip_offsets[s2])
      s2 = s2 + 1
    }
    let mut s3 = 0
    while s3 < strip_counts.length() {
      tiff_put_u32(out, strip_counts[s3])
      s3 = s3 + 1
    }
  }
  Bytes::from_array(out)
}
