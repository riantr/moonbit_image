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
  value : Int32
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

///|
/// Encode an image as an uncompressed TIFF file.
///
/// Greyscale images are written as a single 8-bit channel; colour
/// images as RGB, with the alpha channel kept as a fourth sample when
/// the source has one. A source with a grey alpha channel is expanded
/// to grey + alpha, which loses nothing.
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
  let strip : Array[Byte] = []
  if grayscale {
    let mut i = 0
    while i < pixel_count {
      strip.push(rgba.data[i * 4])
      i = i + 1
    }
  } else if samples == 3 {
    let mut i = 0
    while i < pixel_count {
      strip.push(rgba.data[i * 4]) // R
      strip.push(rgba.data[i * 4 + 1]) // G
      strip.push(rgba.data[i * 4 + 2]) // B
      i = i + 1
    }
  } else {
    let mut i = 0
    while i < pixel_count {
      strip.push(rgba.data[i * 4]) // R
      strip.push(rgba.data[i * 4 + 1]) // G
      strip.push(rgba.data[i * 4 + 2]) // B
      strip.push(rgba.data[i * 4 + 3]) // A
      i = i + 1
    }
  }
  let strip_bytes = Bytes::from_array(strip)

  // --- The IFD ---
  // The entries have to be sorted by tag. BitsPerSample holds one
  // value per sample, so it only fits in the entry itself when there
  // is a single sample.
  let entry_count = if has_alpha { 11 } else { 10 }
  let ifd_offset = 8
  let ifd_size = 2 + entry_count * 12 + 4
  let bits_offset = ifd_offset + ifd_size
  let bits_size = if samples > 1 { samples * 2 } else { 0 }
  let strip_offset = bits_offset + bits_size

  let entries : Array[TiffEntry] = []
  entries.push({
    tag: TIFF_TAG_WIDTH,
    typ: TIFF_TYPE_LONG,
    count: 1,
    value: width,
  })
  entries.push({
    tag: TIFF_TAG_LENGTH,
    typ: TIFF_TYPE_LONG,
    count: 1,
    value: height,
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
  })
  entries.push({
    tag: TIFF_TAG_COMPRESSION,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: 1, // no compression
  })
  entries.push({
    tag: TIFF_TAG_PHOTOMETRIC,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: photometric,
  })
  entries.push({
    tag: TIFF_TAG_STRIP_OFFSETS,
    typ: TIFF_TYPE_LONG,
    count: 1,
    value: strip_offset,
  })
  entries.push({
    tag: TIFF_TAG_SAMPLES_PER_PIXEL,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: samples,
  })
  entries.push({
    tag: TIFF_TAG_ROWS_PER_STRIP,
    typ: TIFF_TYPE_LONG,
    count: 1,
    value: height,
  })
  entries.push({
    tag: TIFF_TAG_STRIP_BYTE_COUNTS,
    typ: TIFF_TYPE_LONG,
    count: 1,
    value: strip_bytes.length(),
  })
  entries.push({
    tag: TIFF_TAG_PLANAR_CONFIGURATION,
    typ: TIFF_TYPE_SHORT,
    count: 1,
    value: 1, // chunky
  })
  if has_alpha {
    // ExtraSamples: 2 means "unassociated alpha".
    entries.push({
      tag: TIFF_TAG_EXTRA_SAMPLES,
      typ: TIFF_TYPE_SHORT,
      count: 1,
      value: 2,
    })
  }

  // --- The file ---
  let out : Array[Byte] = []

  // Header
  out.push(b'I')
  out.push(b'I')
  tiff_put_u16(out, 42)
  tiff_put_u32(out, ifd_offset)

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

  // The BitsPerSample array, for the multi-sample case.
  if samples > 1 {
    let mut s = 0
    while s < samples {
      tiff_put_u16(out, 8)
      s = s + 1
    }
  }

  // The pixel data.
  let mut p = 0
  while p < strip_bytes.length() {
    out.push(strip_bytes[p])
    p = p + 1
  }
  Bytes::from_array(out)
}
