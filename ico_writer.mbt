// Copyright (c) 2025 lws
// ICO container encoder for MoonBit.
//
// Writes a Windows .ico file with a single image:
//
//   ICONDIR (6 bytes)
//     uint16 reserved        // always 0
//     uint16 image_type      // 1 = ICO
//     uint16 num_images      // 1
//
//   ICONDIRENTRY (16 bytes)
//     uint8  width           // 0 means 256
//     uint8  height          // 0 means 256
//     uint8  color_count     // 0 for true colour
//     uint8  reserved
//     uint16 planes          // 1
//     uint16 bit_count       // 32
//     uint32 bytes_in_res
//     uint32 image_offset    // always 22
//
//   image_data
//     a DIB-only bitmap: a BITMAPINFOHEADER, the XOR bitmap (bottom-up
//     BGRA) and the AND mask (1 bit per pixel, rows padded to 4 bytes).
//
// This is the classic form that Windows itself writes for icons below
// 256x256, and the one Pillow, ImageMagick and every icon tool read.
// The Vista+ PNG-in-ICO form would also be valid, but the DIB form
// carries the alpha channel without a second compression pass.
//
// This is a from-scratch implementation: the package has no external
// runtime dependencies, so neither libpng nor a binding to it can be
// used.

///|
/// The number of bytes one row of the AND mask occupies: one bit per
/// pixel, rounded up to a multiple of 4 bytes.
fn ico_mask_stride(width : Int32) -> Int32 {
  (width + 31) / 32 * 4
}

///|
/// Write a 16-bit little-endian value.
fn ico_put_u16(buf : Array[Byte], value : Int32) -> Unit {
  buf.push((value & 0xFF).to_byte())
  buf.push(((value >> 8) & 0xFF).to_byte())
}

///|
/// Write a 32-bit little-endian value.
fn ico_put_u32(buf : Array[Byte], value : Int32) -> Unit {
  buf.push((value & 0xFF).to_byte())
  buf.push(((value >> 8) & 0xFF).to_byte())
  buf.push(((value >> 16) & 0xFF).to_byte())
  buf.push(((value >> 24) & 0xFF).to_byte())
}

///|
/// Encode an image as a Windows ICO file with a single 32-bit entry.
///
/// The icon keeps the alpha channel of the source image. An icon is
/// limited to 256x256 pixels.
///
/// # Errors
///
/// Raises `Failure` if the image has zero width or height, or if it is
/// larger than 256x256.
pub fn encode_ico(image : Image) -> Bytes raise Failure {
  if image.width <= 0 || image.height <= 0 {
    raise Failure::Failure(
      "ICO encode: image dimensions must be positive, got \{image.width}x\{image.height}",
    )
  }
  if image.width > 256 || image.height > 256 {
    raise Failure::Failure(
      "ICO encode: an icon cannot be larger than 256x256, got \{image.width}x\{image.height}",
    )
  }

  let rgba = image.to_rgba8()
  let width = rgba.width
  let height = rgba.height

  // --- The DIB payload: header, XOR bitmap, AND mask ---
  let payload : Array[Byte] = []

  // BITMAPINFOHEADER. The height covers the XOR bitmap *and* the AND
  // mask, so it is twice the icon height.
  ico_put_u32(payload, 40) // biSize
  ico_put_u32(payload, width) // biWidth
  ico_put_u32(payload, height * 2) // biHeight
  ico_put_u16(payload, 1) // biPlanes
  ico_put_u16(payload, 32) // biBitCount
  ico_put_u32(payload, 0) // biCompression = BI_RGB
  ico_put_u32(payload, 0) // biSizeImage
  ico_put_u32(payload, 0) // biXPelsPerMeter
  ico_put_u32(payload, 0) // biYPelsPerMeter
  ico_put_u32(payload, 0) // biClrUsed
  ico_put_u32(payload, 0) // biClrImportant

  // The XOR bitmap: bottom-up rows of BGRA pixels.
  let mut y = height - 1
  while y >= 0 {
    let mut x = 0
    while x < width {
      let i = (y * width + x) * 4
      payload.push(rgba.data[i + 2]) // B
      payload.push(rgba.data[i + 1]) // G
      payload.push(rgba.data[i]) // R
      payload.push(rgba.data[i + 3]) // A
      x = x + 1
    }
    y = y - 1
  }

  // The AND mask: one bit per pixel, all zero because the alpha channel
  // of the XOR bitmap already carries the transparency. Rows are padded
  // to a multiple of 4 bytes.
  let mask_stride = ico_mask_stride(width)
  let mut row = 0
  while row < height {
    let mut i = 0
    while i < mask_stride {
      payload.push(b'\x00')
      i = i + 1
    }
    row = row + 1
  }

  let payload_bytes = Bytes::from_array(payload)

  // --- The container ---
  let out : Array[Byte] = []
  ico_put_u16(out, 0) // reserved
  ico_put_u16(out, 1) // image_type: icon
  ico_put_u16(out, 1) // one image
  // ICONDIRENTRY
  out.push((if width == 256 { 0 } else { width }).to_byte())
  out.push((if height == 256 { 0 } else { height }).to_byte())
  out.push(b'\x00') // colour count: 0 for true colour
  out.push(b'\x00') // reserved
  ico_put_u16(out, 1) // planes
  ico_put_u16(out, 32) // bit count
  ico_put_u32(out, payload_bytes.length())
  ico_put_u32(out, 22) // image offset: right after the directory
  let mut i = 0
  while i < payload_bytes.length() {
    out.push(payload_bytes[i])
    i = i + 1
  }
  Bytes::from_array(out)
}
