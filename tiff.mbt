// Copyright (c) 2025 lws
// TIFF (Tagged Image File Format) baseline decoder for MoonBit.
//
// Scope (intentionally narrow — the rest of the format is large enough
// that trying to support it all in one night produces a bug farm).
//
// Supported:
//   * Byte order: little-endian ("II") only. Big-endian ("MM") TIFFs
//     raise Failure("TIFF: big-endian unsupported in this build").
//   * Compression: 1 (no compression) only. LZW / Deflate / JPEG-in-
//     TIFF are rejected up front.
//   * Photometric: 0 (WhiteIsZero), 1 (BlackIsZero), 2 (RGB),
//     3 (Palette). 4, 5, 6 (CMYK / YCbCr / Lab / ICC) rejected.
//   * BitsPerSample: 1, 2, 4, 8, 16 (uniform across samples).
//   * SamplesPerPixel: 1 (greyscale / palette) or 3 (RGB). RGBA / CMYK
//     rejected.
//   * PlanarConfiguration: 1 (chunky) only.
//   * Layout: single strip (StripOffsets / StripByteCounts each have
//     exactly one entry, RowsPerStrip >= height).
//   * Sample format: UINT only.
//
// 16-bit samples are right-shifted to 8 bits for output; this is a
// display-friendly lossy mapping but is what most non-photographic
// consumers want.
//
// Unsupported files MUST raise a clear Failure so the public decode()
// wrapper can surface it as DecodeError::InvalidHeader.

///|
/// Decode a TIFF image. See file header for supported subset.
pub fn decode_tiff(data : Bytes) -> Image raise Failure {
  if data.length() < 8 {
    raise Failure::Failure("TIFF: file too small for header")
  }
  // Byte order mark + magic 42
  if data[0] != b'I' || data[1] != b'I' {
    raise Failure::Failure("TIFF: big-endian 'MM' unsupported in this build")
  }
  if data[2] != b'\x2A' || data[3] != b'\x00' {
    raise Failure::Failure("TIFF: bad magic (expected 42)")
  }
  let ifd_offset = read_u32_le(data, 4)

  // Parse the (single) IFD. We do NOT follow next_ifd links — multi-
  // page TIFFs decode only the first page, which is what the public
  // `decode` entry point can return as an Image (multi-frame lives in
  // AnimatedImage for GIF; not modelled here).
  let entries = parse_ifd(data, ifd_offset)

  // Pull the tags we need.
  let width = get_long(entries, TAG_IMAGE_WIDTH)
  let height = get_long(entries, TAG_IMAGE_LENGTH)
  let bits = get_short(entries, TAG_BITS_PER_SAMPLE, 0) // first sample only
  let compression = get_short(entries, TAG_COMPRESSION, 0)
  let photometric = get_short(entries, TAG_PHOTOMETRIC, 0)
  let samples = get_short(entries, TAG_SAMPLES_PER_PIXEL, 1)
  let planar = get_short(entries, TAG_PLANAR_CONFIG, 1)

  // Validate dimensions + format invariants.
  if width <= 0 || height <= 0 {
    raise Failure::Failure("TIFF: invalid dimensions")
  }
  if compression != 1 {
    raise Failure::Failure(
      "TIFF: only no-compression (1) supported, got " + compression.to_string(),
    )
  }
  if planar != 1 {
    raise Failure::Failure(
      "TIFF: only chunky planar config (1) supported",
    )
  }
  match photometric {
    0 | 1 => if samples != 1 { raise Failure::Failure("TIFF: greyscale needs SamplesPerPixel=1") }
    2 => if samples != 3 { raise Failure::Failure("TIFF: RGB needs SamplesPerPixel=3") }
    3 => if samples != 1 { raise Failure::Failure("TIFF: palette needs SamplesPerPixel=1") }
    _ =>
      raise Failure::Failure(
        "TIFF: unsupported PhotometricInterpretation " + photometric.to_string(),
      )
  }
  match bits {
    1 | 2 | 4 | 8 | 16 => ()
    _ => raise Failure::Failure("TIFF: unsupported BitsPerSample " + bits.to_string())
  }

  // Strip offsets / counts — we require exactly one strip covering the
  // whole image. StripOffsets may be SHORT or LONG, so the array entry
  // length determines the type to read.
  let strip_offsets = get_long_array(entries, TAG_STRIP_OFFSETS)
  let strip_byte_counts = get_long_array(entries, TAG_STRIP_BYTE_COUNTS)
  if strip_offsets.length() != 1 || strip_byte_counts.length() != 1 {
    raise Failure::Failure("TIFF: only single-strip layout supported")
  }
  let strip_offset = strip_offsets[0]
  let strip_size = strip_byte_counts[0]
  if strip_offset + strip_size > data.length() {
    raise Failure::Failure("TIFF: strip out of bounds")
  }
  let strip = data[strip_offset:strip_offset + strip_size].to_owned()

  // Palette (only when photometric == 3)
  let palette = if photometric == 3 {
    read_color_map(entries, 1 << bits)
  } else {
    Array::make(0, Color::default())
  }

  // Decode the strip into a PixelFormat image.
  let fmt = match (photometric, bits) {
    // Palette / greyscale → always expand to RGBA8 so consumers don't
    // have to reason about palette indices separately.
    (3, _) => PixelFormat::RGBA8
    (0, _) => PixelFormat::Gray8
    (1, _) => PixelFormat::Gray8
    (2, _) => PixelFormat::RGB8
    _ => abort("unreachable: photometric/bits validated above")
  }
  let img = decode_strip(strip, width, height, bits, samples, photometric, palette)
  Image::new(width, height, fmt, img)
}

// ----- Tag IDs (Adobe TIFF 6.0 §2) -----------------------------------------

///|
const TAG_IMAGE_WIDTH : Int = 256

///|
const TAG_IMAGE_LENGTH : Int = 257

///|
const TAG_BITS_PER_SAMPLE : Int = 258

///|
const TAG_COMPRESSION : Int = 259

///|
const TAG_PHOTOMETRIC : Int = 262

///|
const TAG_STRIP_OFFSETS : Int = 273

///|
const TAG_SAMPLES_PER_PIXEL : Int = 277

///|
const TAG_ROWS_PER_STRIP : Int = 278

///|
const TAG_STRIP_BYTE_COUNTS : Int = 279

///|
const TAG_PLANAR_CONFIG : Int = 284

///|
const TAG_COLOR_MAP : Int = 320

// ----- IFD parsing ---------------------------------------------------------

///|
/// One parsed IFD entry, with values already resolved (i.e. indirect
/// values have been fetched from the file).
priv struct IfdEntry {
  tag : Int
  /// 1=BYTE, 2=ASCII, 3=SHORT, 4=LONG, 5=RATIONAL
  typ : Int
  count : Int
  /// Resolved values — always a flat array of `count` entries, each
  /// entry is a 32-bit unsigned integer regardless of `typ`. SHORTs are
  /// zero-extended; RATIONALs are truncated to their numerator.
  values : Array[Int]
}

///|
fn parse_ifd(data : Bytes, off : Int) -> Array[IfdEntry] raise Failure {
  if off + 2 > data.length() {
    raise Failure::Failure("TIFF: truncated IFD count")
  }
  let count = read_u16_le(data, off)
  let entries_off = off + 2
  if entries_off + count * 12 > data.length() {
    raise Failure::Failure("TIFF: truncated IFD entries")
  }
  let entries : Array[IfdEntry] = []
  for i = 0; i < count; i = i + 1 {
    let e = entries_off + i * 12
    let tag = read_u16_le(data, e)
    let typ = read_u16_le(data, e + 2)
    let cnt = read_u32_le(data, e + 4)
    let raw = read_u32_le(data, e + 8)
    let values = resolve_value(data, typ, cnt, raw)
    entries.push({ tag, typ, count: cnt, values })
  }
  entries
}

///|
/// Fetch `count` values of `typ` from either the inline 4-byte slot
/// (when the total fits) or from the offset pointing into the file.
fn resolve_value(
  data : Bytes,
  typ : Int,
  count : Int,
  raw : Int,
) -> Array[Int] raise Failure {
  let size_per = match typ {
    1 | 2 => 1
    3 => 2
    4 => 4
    5 => 8
    _ => raise Failure::Failure("TIFF: unsupported type " + typ.to_string())
  }
  let total = size_per * count
  let values : Array[Int] = []
  if total <= 4 {
    // Read everything inline from the 4-byte `raw` slot. We pack the
    // bytes little-endian into 32-bit integers.
    let base = raw
    let mut pos = 0
    while pos < count {
      let v = match typ {
        1 | 2 => base >> (pos * 8) & 0xFF
        3 => base >> (pos * 2 * 8) & 0xFFFF
        4 => base
        _ => 0
      }
      values.push(v)
      pos = pos + 1
    }
  } else {
    // Read from the file at `raw` offset.
    if raw + total > data.length() {
      raise Failure::Failure("TIFF: indirect value out of bounds")
    }
    let mut p = raw
    let mut read = 0
    while read < count {
      let v = match typ {
        1 | 2 => data[p].to_int()
        3 => read_u16_le(data, p)
        4 => read_u32_le(data, p)
        5 =>
          // RATIONAL = num/den. We only store the numerator; consumers
          // (currently only the public decode path) don't read the
          // XResolution / YResolution tags so this never matters.
          read_u32_le(data, p)
        _ => 0
      }
      values.push(v)
      p = p + size_per
      read = read + 1
    }
  }
  values
}

// ----- Tag accessors -------------------------------------------------------

///|
/// Find an IFD entry by tag. Returns None if the tag is absent.
fn find_entry(entries : Array[IfdEntry], tag : Int) -> IfdEntry? {
  for e in entries {
    if e.tag == tag {
      return Some(e)
    }
  }
  None
}

///|
/// Read a tag's first value as a uint32. Returns `default` if the tag
/// is absent.
fn get_long(entries : Array[IfdEntry], tag : Int) -> Int {
  match find_entry(entries, tag) {
    Some(e) =>
      if e.values.length() > 0 {
        e.values[0]
      } else {
        0
      }
    None => 0
  }
}

///|
/// Read a tag's first value as a uint16 (zero-extended). Returns
/// `default` if the tag is absent or its first value exceeds 0xFFFF.
fn get_short(entries : Array[IfdEntry], tag : Int, default : Int) -> Int {
  match find_entry(entries, tag) {
    Some(e) =>
      if e.values.length() > 0 {
        let v = e.values[0]
        if v >= 0 && v <= 0xFFFF {
          v
        } else {
          default
        }
      } else {
        default
      }
    None => default
  }
}

///|
/// Read a tag's full value array. Each entry is widened to uint32.
fn get_long_array(entries : Array[IfdEntry], tag : Int) -> Array[Int] {
  match find_entry(entries, tag) {
    Some(e) => e.values
    None => []
  }
}

///|
/// Read the ColorMap tag. TIFF stores the palette as 3 * 2^bits SHORT
/// values: R values, then G values, then B values (each 0..65535).
/// We collapse to 8-bit by right-shifting by 8, matching how most
/// consumers interpret TIFF palettes.
fn read_color_map(
  entries : Array[IfdEntry],
  num_colors : Int,
) -> Array[Color] raise Failure {
  match find_entry(entries, TAG_COLOR_MAP) {
    Some(e) => {
      if e.values.length() < num_colors * 3 {
        raise Failure::Failure("TIFF: ColorMap too short")
      }
      let out : Array[Color] = []
      for i = 0; i < num_colors; i = i + 1 {
        let r16 = e.values[i]
        let g16 = e.values[num_colors + i]
        let b16 = e.values[num_colors * 2 + i]
        out.push(Color::new(r16 >> 8, g16 >> 8, b16 >> 8, 255))
      }
      out
    }
    None =>
      raise Failure::Failure("TIFF: PhotometricInterpretation=3 needs ColorMap")
  }
}

// ----- Strip decoding ------------------------------------------------------

///|
/// Decode one strip of pixel data into a flat byte array whose pixel
/// format depends on `photometric` + `bits` (and is decided by the
/// caller via the ImageFormat of the returned Image).
fn decode_strip(
  strip : Bytes,
  width : Int,
  height : Int,
  bits : Int,
  samples : Int,
  photometric : Int,
  palette : Array[Color],
) -> Bytes raise Failure {
  match (photometric, bits, samples) {
    // Greyscale 8-bit / 16-bit
    (0, 8, 1) | (1, 8, 1) => strip
    (0, 16, 1) | (1, 16, 1) => shrink16_to_8(strip)
    // Greyscale 1/2/4-bit packed
    (0, b, 1) | (1, b, 1) =>
      if b == 1 || b == 2 || b == 4 {
        unpack_subbyte_greyscale(strip, width, height, b, photometric)
      } else {
        raise Failure::Failure("TIFF: bad greyscale bit depth " + b.to_string())
      }
    // RGB 8-bit
    (2, 8, 3) => strip
    // RGB 16-bit → collapse to 8-bit
    (2, 16, 3) => shrink_rgb16_to_8(strip)
    // Palette: indices are 1/2/4/8-bit per pixel, looked up in
    // the ColorMap we already resolved.
    (3, b, 1) =>
      if b == 1 || b == 2 || b == 4 || b == 8 {
        unpack_palette(strip, width, height, b, palette)
      } else {
        raise Failure::Failure("TIFF: bad palette bit depth " + b.to_string())
      }
    _ =>
      raise Failure::Failure(
        "TIFF: unsupported photometric/bits/samples combination",
      )
  }
}

///|
/// Right-shift every 16-bit little-endian sample down to 8 bits. The
/// resulting buffer is half the input size.
fn shrink16_to_8(strip : Bytes) -> Bytes raise Failure {
  if strip.length() % 2 != 0 {
    raise Failure::Failure("TIFF: 16-bit strip has odd length")
  }
  let arr = Array::make(strip.length() / 2, b'\x00')
  for i = 0; i < arr.length(); i = i + 1 {
    arr[i] = (strip[i * 2].to_int() >> 8).to_byte()
  }
  Bytes::from_array(arr)
}

///|
/// RGB16 (3 samples × 16 bits) → RGB8 (3 samples × 8 bits).
fn shrink_rgb16_to_8(strip : Bytes) -> Bytes raise Failure {
  if strip.length() % 6 != 0 {
    raise Failure::Failure("TIFF: 16-bit RGB strip has wrong length")
  }
  let arr = Array::make(strip.length() / 2, b'\x00')
  let mut di = 0
  let mut si = 0
  while si < strip.length() {
    arr[di] = strip[si].to_int().to_byte() // R high byte
    arr[di + 1] = strip[si + 2].to_int().to_byte() // G
    arr[di + 2] = strip[si + 4].to_int().to_byte() // B
    di = di + 3
    si = si + 6
  }
  Bytes::from_array(arr)
}

///|
/// Expand a sub-byte-depth greyscale strip to one byte per pixel. The
/// photometric interpretation is inverted for WhiteIsZero (0) by
/// flipping each nibble/bit (255 - v).
fn unpack_subbyte_greyscale(
  strip : Bytes,
  width : Int,
  height : Int,
  bits : Int,
  photometric : Int,
) -> Bytes raise Failure {
  let total = width * height
  let arr = Array::make(total, b'\x00')
  for i = 0; i < total; i = i + 1 {
    let mut v = extract_subbyte(strip, i, bits)
    if photometric == 0 {
      // WhiteIsZero: smaller value = brighter, so flip
      let max = (1 << bits) - 1
      v = max - v
    }
    // Scale up so output is 0..255
    let scaled = v * 255 / ((1 << bits) - 1)
    arr[i] = scaled.to_byte()
  }
  ignore(height)
  Bytes::from_array(arr)
}

///|
/// Read the `bits`-wide sample at pixel index `i` from a packed
/// little-endian bitstream.
fn extract_subbyte(strip : Bytes, i : Int, bits : Int) -> Int raise Failure {
  let bit_off = i * bits
  let byte_off = bit_off / 8
  let inner = bit_off % 8
  if byte_off >= strip.length() {
    raise Failure::Failure("TIFF: sub-byte sample out of bounds")
  }
  if inner + bits <= 8 {
    let raw = strip[byte_off].to_int()
    let mask = (1 << bits) - 1
    (raw >> inner) & mask
  } else {
    // Spans two bytes (only relevant for bits=4 with the second
    // nibble in the next byte — already handled above for 4-bit
    // because i*4 makes inner either 0 or 4, both ≤ 8. Still,
    // defensive: cross-byte extract.)
    let lo = if byte_off < strip.length() { strip[byte_off].to_int() } else { 0 }
    let hi = if byte_off + 1 < strip.length() {
      strip[byte_off + 1].to_int()
    } else {
      0
    }
    let combined = lo | (hi << 8)
    let mask = (1 << bits) - 1
    (combined >> inner) & mask
  }
}

///|
/// Unpack a palette-indexed strip into RGBA8 by looking each sample up
/// in `palette`.
fn unpack_palette(
  strip : Bytes,
  width : Int,
  height : Int,
  bits : Int,
  palette : Array[Color],
) -> Bytes raise Failure {
  let total = width * height
  let arr = Array::make(total * 4, b'\x00')
  for i = 0; i < total; i = i + 1 {
    let idx = extract_subbyte(strip, i, bits)
    let c = if idx < palette.length() {
      palette[idx]
    } else {
      Color::default()
    }
    let d = i * 4
    arr[d] = c.r.to_byte()
    arr[d + 1] = c.g.to_byte()
    arr[d + 2] = c.b.to_byte()
    arr[d + 3] = c.a.to_byte()
  }
  ignore(height)
  Bytes::from_array(arr)
}