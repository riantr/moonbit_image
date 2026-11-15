// Copyright (c) 2025 lws
// TGA (Truevision TARGA) encoder
//
// Writes uncompressed and RLE-compressed TGA files:
//
//   - type 2  (uncompressed true-color) / type 10 (RLE true-color)
//   - type 3  (uncompressed greyscale)  / type 11 (RLE greyscale)
//
// Pixels are written top-to-bottom (the top-origin bit of the image
// descriptor), so no row reversal is needed, and in BGR / BGRA order,
// which is what TGA stores.
//
// Specification: Truevision TARGA image file format, version 2.0

//-----------------------------------------------------------------------------
// Helpers
//-----------------------------------------------------------------------------

///|
/// Whether the image contains a pixel that is not fully opaque.
fn tga_has_alpha(image : Image) -> Bool {
  let rgba = image.to_rgba8()
  let pixel_count = rgba.width * rgba.height
  let mut found = false
  let mut i = 0
  while i < pixel_count {
    if rgba.data[i * 4 + 3] != b'\xFF' {
      found = true
      break
    }
    i = i + 1
  }
  found
}

///|
/// The pixel data in TGA's storage order (BGR or BGRA), row by row,
/// top to bottom.
fn tga_pixel_bytes(image : Image, bpp : Int32) -> Array[Byte] {
  let rgba = image.to_rgba8()
  let pixel_count = rgba.width * rgba.height
  let out = Array::make(pixel_count * bpp, b'\x00')
  let src = rgba.data
  let mut i = 0
  while i < pixel_count {
    let s = i * 4
    let d = i * bpp
    out[d] = src[s + 2] // B
    out[d + 1] = src[s + 1] // G
    out[d + 2] = src[s] // R
    if bpp == 4 {
      out[d + 3] = src[s + 3] // A
    }
    i = i + 1
  }
  out
}

///|
/// The greyscale sample of every pixel.
fn tga_gray_bytes(image : Image) -> Array[Byte] {
  let rgba = image.to_rgba8()
  let pixel_count = rgba.width * rgba.height
  let out = Array::make(pixel_count, b'\x00')
  let mut i = 0
  while i < pixel_count {
    let r = rgba.data[i * 4].to_int()
    let g = rgba.data[i * 4 + 1].to_int()
    let b = rgba.data[i * 4 + 2].to_int()
    // ITU-R BT.601 luma, the same conversion the package uses elsewhere.
    // A Gray8 image has r == g == b, so this reproduces the sample
    // exactly.
    out[i] = ((r * 299 + g * 587 + b * 114) / 1000).to_byte()
    i = i + 1
  }
  out
}

///|
/// Whether the `bpp`-byte pixel at index `a` equals the one at index `b`.
fn tga_same_pixel(
  data : Array[Byte],
  a : Int32,
  b : Int32,
  bpp : Int32,
) -> Bool {
  let pa = a * bpp
  let pb = b * bpp
  let mut i = 0
  while i < bpp {
    if data[pa + i] != data[pb + i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Run-length encode the pixel data into TGA RLE packets.
///
/// The packet header's high bit selects the kind of packet, per the
/// Truevision TGA File Format Specification v2.0, "Image Data":
///
///   - high bit SET   -> run-length packet: the single pixel that follows
///     is repeated `header & 0x7F` + 1 times.
///   - high bit CLEAR -> raw packet: the next `header & 0x7F` + 1 pixels
///     follow verbatim.
///
/// Both kinds carry at most 128 pixels, and neither is allowed to cross
/// a scan line: the v2.0 specification says run-length packets should
/// never encode pixels from more than one scan line.
fn tga_rle_packets(
  data : Array[Byte],
  pixel_count : Int32,
  width : Int32,
  bpp : Int32,
) -> Array[Byte] {
  let out = []
  let mut i = 0
  while i < pixel_count {
    // How many pixels are left on this scan line?
    let row_left = width - i % width
    let row_limit = if row_left < 128 { row_left } else { 128 }

    // How long is the run of identical pixels starting here?
    let mut run = 1
    while i + run < pixel_count &&
          run < row_limit &&
          tga_same_pixel(data, i, i + run, bpp) {
      run = run + 1
    }

    if run >= 2 {
      // Run-length packet.
      out.push((0x80 | (run - 1)).to_byte())
      let base = i * bpp
      let mut k = 0
      while k < bpp {
        out.push(data[base + k])
        k = k + 1
      }
      i = i + run
    } else {
      // Raw packet: gather pixels until a run of two or more starts, or
      // until the packet or the scan line is full.
      let start = i
      let mut count = 0
      while i < pixel_count && count < row_limit {
        if count > 0 &&
          i + 1 < pixel_count &&
          tga_same_pixel(data, i, i + 1, bpp) {
          break
        }
        i = i + 1
        count = count + 1
      }
      out.push((count - 1).to_byte())
      let mut k = 0
      while k < count * bpp {
        out.push(data[start * bpp + k])
        k = k + 1
      }
    }
  }
  out
}

//-----------------------------------------------------------------------------
// TGA encoder
//-----------------------------------------------------------------------------

///|
/// Encode an image as an uncompressed TGA file.
///
/// A greyscale image becomes a type 3 file with 8-bit samples. Every
/// other format is converted to RGBA8 and written as a type 2 file:
/// 24-bit BGR when the image is fully opaque, 32-bit BGRA when it has
/// transparency. Rows are written top to bottom.
///
/// # Errors
///
/// Raises `Failure` if the image has zero width or height.
pub fn encode_tga(image : Image) -> Bytes raise Failure {
  encode_tga_generic(image, false)
}

///|
/// Encode an image as a run-length encoded TGA file.
///
/// Same colour handling as `encode_tga`, but the pixel data is packed
/// into RLE packets (type 10 / type 11), which is much smaller for
/// images with large flat areas.
///
/// # Errors
///
/// Raises `Failure` if the image has zero width or height.
pub fn encode_tga_rle(image : Image) -> Bytes raise Failure {
  encode_tga_generic(image, true)
}

///|
/// The shared implementation of the two TGA encoders.
fn encode_tga_generic(image : Image, rle : Bool) -> Bytes raise Failure {
  if image.width <= 0 || image.height <= 0 {
    raise Failure::Failure(
      "TGA encode: image dimensions must be positive, got \{image.width}x\{image.height}",
    )
  }

  let grayscale = match image.format {
    PixelFormat::Gray8 => true
    _ => false
  }
  let bpp = if grayscale { 1 } else if tga_has_alpha(image) { 4 } else { 3 }
  let image_type = if grayscale {
    if rle {
      11
    } else {
      3
    }
  } else if rle {
    10
  } else {
    2
  }

  let pixels = if grayscale {
    tga_gray_bytes(image)
  } else {
    tga_pixel_bytes(image, bpp)
  }
  let pixel_count = image.width * image.height
  let payload = if rle {
    tga_rle_packets(pixels, pixel_count, image.width, bpp)
  } else {
    pixels
  }

  // 18 byte header + the pixel data.
  let out = Array::make(18 + payload.length(), b'\x00')

  out[0] = b'\x00' // id length
  out[1] = b'\x00' // colour map type: none
  out[2] = image_type.to_byte()
  // bytes 3..11: colour map and origin fields, all zero
  write_u16_le(out, 12, image.width)
  write_u16_le(out, 14, image.height)
  out[16] = (bpp * 8).to_byte() // pixel depth
  // Bit 5 selects a top-to-bottom image; the low nibble is the number
  // of attribute bits per pixel.
  out[17] = if bpp == 4 { b'\x28' } else { b'\x20' }

  let mut i = 0
  while i < payload.length() {
    out[18 + i] = payload[i]
    i = i + 1
  }

  Bytes::from_array(out)
}
