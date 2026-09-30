// Copyright (c) 2025 lws
// Image decoding library for MoonBit - Main entry point

//-----------------------------------------------------------------------------
// Format Detection
//-----------------------------------------------------------------------------

///|
/// Detect the image format from magic bytes (file signature)
/// PNG and QOI have distinctive signatures, BMP has "BM", TGA uses heuristic + footer
pub fn detect_format(data : Bytes) -> ImageFormat? {
  // Each magic check is responsible for its own minimum length; an
  // outer `if length < 8` would falsely reject 6-byte GIF / 4-byte QOI
  // / 2-byte BMP / 3-byte JPEG signatures.

  // PNG: \x89 P N G \r \n \x1A \n (8-byte signature)
  if data.length() >= 8 &&
    data[0] == b'\x89' &&
    data[1] == b'P' &&
    data[2] == b'N' &&
    data[3] == b'G' &&
    data[4] == b'\r' &&
    data[5] == b'\n' &&
    data[6] == b'\x1A' &&
    data[7] == b'\n' {
    return Some(ImageFormat::PNG)
  }

  // QOI: q o i f (4-byte magic)
  if data.length() >= 4 &&
    data[0] == b'q' &&
    data[1] == b'o' &&
    data[2] == b'i' &&
    data[3] == b'f' {
    return Some(ImageFormat::QOI)
  }

  // GIF: G I F 8 7 a or G I F 8 9 a (6-byte signature)
  if data.length() >= 6 &&
    data[0] == b'G' &&
    data[1] == b'I' &&
    data[2] == b'F' &&
    data[3] == b'8' &&
    (data[4] == b'7' || data[4] == b'9') &&
    data[5] == b'a' {
    return Some(ImageFormat::GIF)
  }

  // BMP: B M (2-byte signature)
  if data.length() >= 2 && data[0] == b'B' && data[1] == b'M' {
    return Some(ImageFormat::BMP)
  }

  // FIM: J A (2-byte magic) - CETC BVE-series X-ray security-scanner
  // raw detector stream. Distinct from BMP's 'B' 'M' so order-independent.
  if data.length() >= 2 && data[0] == b'J' && data[1] == b'A' {
    return Some(ImageFormat::FIM)
  }

  // TGA detection: check for type 2 footer first (most reliable),
  // then fall back to header heuristic (requires >= 18 bytes).
  if detect_tga(data) {
    return Some(ImageFormat::TGA)
  }

  // JPEG: FF D8 FF marker (check this last since FF D8 can appear in other binary data)
  if data.length() >= 3 && data[0] == b'\xFF' && data[1] == b'\xD8' {
    return Some(ImageFormat::JPEG)
  }

  // TIFF: byte-order mark "II" (little) or "MM" (big) + magic 42.
  // Little-endian 42 stores as 0x2A 0x00; big-endian 42 as 0x00 0x2A.
  if data.length() >= 4 {
    if data[0] == b'I' &&
      data[1] == b'I' &&
      data[2] == b'\x2A' &&
      data[3] == b'\x00' {
      return Some(ImageFormat::TIFF)
    }
    if data[0] == b'M' &&
      data[1] == b'M' &&
      data[2] == b'\x00' &&
      data[3] == b'\x2A' {
      return Some(ImageFormat::TIFF)
    }
  }

  // ICO: reserved(2)=0, type(2)=1 (icon), count(2) >= 1.
  // The reserved-zero prefix is too generic to use alone, so we
  // require the type=1 marker AND a non-zero entry count.
  if data.length() >= 6 &&
    data[0] == b'\x00' &&
    data[1] == b'\x00' &&
    data[2] == b'\x01' &&
    data[3] == b'\x00' &&
    data[4] >= b'\x01' {
    return Some(ImageFormat::ICO)
  }

  None
}

///|
/// Try to detect TGA by footer or header heuristic
fn detect_tga(data : Bytes) -> Bool {
  if data.length() < 18 {
    return false
  }

  // Method 1: Check for TGA version 2 footer at end of file
  // Footer signature: "TRUEVISION-XFILE." at position len-18
  let footer_sig = "TRUEVISION-XFILE."
  let len = data.length()
  if len >= 26 {
    let footer_start = len - 18
    let mut matches = true
    for i = 0; i < 18; i = i + 1 {
      if data[footer_start + i] != footer_sig[i].to_byte() {
        matches = false
        break
      }
    }
    if matches {
      return true
    }
  }

  // Method 2: Header heuristic for type 1 (no footer) TGA files
  let id_length = data[0].to_int()
  let color_map_type = data[1].to_int()
  let image_type = data[2].to_int()

  // Valid TGA image types (2=uncompressed true-color, 3=grayscale, 10=RLE true-color, 11=RLE grayscale)
  let valid_type = image_type == 2 ||
    image_type == 3 ||
    image_type == 10 ||
    image_type == 11
  // Valid color map types (0=none, 1=present)
  let valid_cmap = color_map_type == 0 || color_map_type == 1

  if !valid_type || !valid_cmap {
    return false
  }

  // Validate dimensions
  let width = data[12].to_int() | (data[13].to_int() << 8)
  let height = data[14].to_int() | (data[15].to_int() << 8)
  if width == 0 || height == 0 {
    return false
  }

  let pixel_depth = data[16].to_int()
  let valid_depth = pixel_depth == 8 ||
    pixel_depth == 16 ||
    pixel_depth == 24 ||
    pixel_depth == 32

  id_length >= 0 && id_length < 256 && valid_depth
}

//-----------------------------------------------------------------------------
// Unified Decode API
//
// Public decode / encode entry points raise the structured `DecodeError`
// suberror. The per-codec helpers (decode_bmp, decode_qoi, ...) and the
// low-level byte readers (read_u32_le, ...) keep raising the MoonBit
// built-in `Failure` suberror; the wrappers below translate any
// `Failure` they surface into a `DecodeError::InvalidHeader` (the
// underlying message is preserved so debug logs still tell you what the
// codec actually rejected).
//-----------------------------------------------------------------------------

///|
/// Auto-detect format and decode an image from raw bytes.
///
/// Raises `DecodeError::UnsupportedFormat` if the byte stream does not
/// match any known signature. Wraps every codec-internal `Failure` as
/// `DecodeError::InvalidHeader` so callers only need to match on one
/// error type.
pub fn decode(data : Bytes) -> Image raise DecodeError {
  match detect_format(data) {
    None => raise DecodeError::UnsupportedFormat("unknown image format")
    Some(format) =>
      match (try? decode_by_format_raw(data, format)) {
        Ok(img) => img
        Err(Failure::Failure(msg)) => raise DecodeError::InvalidHeader(msg)
      }
  }
}

///|
/// Decode an image with a known format. Internal codec failures are
/// wrapped as `DecodeError::InvalidHeader`; no format-detection step
/// happens, so `UnsupportedFormat` is not raised from this entry point.
pub fn decode_by_format(
  data : Bytes,
  format : ImageFormat,
) -> Image raise DecodeError {
  match (try? decode_by_format_raw(data, format)) {
    Ok(img) => img
    Err(Failure::Failure(msg)) => raise DecodeError::InvalidHeader(msg)
  }
}

///|
/// Internal: dispatch to the right per-format raw decoder and let its
/// own `Failure` propagate. The two public wrappers above catch that
/// failure and re-raise as `DecodeError`.
fn decode_by_format_raw(
  data : Bytes,
  format : ImageFormat,
) -> Image raise Failure {
  match format {
    ImageFormat::BMP => decode_bmp(data)
    ImageFormat::QOI => decode_qoi(data)
    ImageFormat::TGA => decode_tga(data)
    ImageFormat::PNG => decode_png(data)
    ImageFormat::GIF => decode_gif(data)
    ImageFormat::JPEG => decode_jpeg(data)
    ImageFormat::ICO => decode_ico(data)
    ImageFormat::TIFF => decode_tiff(data)
    ImageFormat::FIM => decode_fim(data)
  }
}

//-----------------------------------------------------------------------------
// Header-only dimension reading (fast, no pixel decoding)
//-----------------------------------------------------------------------------

///|
/// Get image dimensions from a file header without decoding pixels.
/// Much faster than `decode()` for inspecting image metadata.
pub fn image_dimensions(data : Bytes) -> (Int, Int, ImageFormat) raise DecodeError {
  match detect_format(data) {
    None => raise DecodeError::UnsupportedFormat("unknown image format")
    Some(format) =>
      match (try? image_dimensions_raw(data, format)) {
        Ok(dims) => dims
        Err(Failure::Failure(msg)) => raise DecodeError::InvalidHeader(msg)
      }
  }
}

///|
/// Internal: dispatch to the right per-format raw header reader.
fn image_dimensions_raw(
  data : Bytes,
  format : ImageFormat,
) -> (Int, Int, ImageFormat) raise Failure {
  match format {
    ImageFormat::BMP => bmp_dimensions(data)
    ImageFormat::QOI => qoi_dimensions(data)
    ImageFormat::TGA => tga_dimensions(data)
    ImageFormat::PNG => png_dimensions(data)
    ImageFormat::GIF => gif_dimensions(data)
    ImageFormat::JPEG => {
      let (w, h) = jpeg_dimensions(data)
      (w, h, ImageFormat::JPEG)
    }
    // ICO + TIFF require walking the directory; we fall back to
    // decode() for them and let the byte-level pixel data carry the
    // dimensions. This keeps the fast path cheap for the simple
    // formats where it matters.
    ImageFormat::ICO | ImageFormat::TIFF => {
      let img = decode_by_format_raw(data, format)
      (img.width, img.height, format)
    }
    // FIM: raw detector (width, height), header-only read; decode_fim
    // returns the side-by-side 2*width x height/2 display image, so
    // we report the detector grid here to match decode_fim_raw and
    // the public `fim_dimensions` helper.
    ImageFormat::FIM => {
      let (w, h) = fim_dimensions(data)
      (w, h, ImageFormat::FIM)
    }
  }
}

///|
/// Read BMP dimensions from header (fast, no pixel decode)
fn bmp_dimensions(data : Bytes) -> (Int, Int, ImageFormat) raise Failure {
  if data.length() < 26 {
    raise Failure::Failure("BMP: file too small for header reading")
  }
  let width = read_u32_le(data, 18)
  // BMP uses a signed int32 for height: a negative value means
  // top-down row order; we only care about magnitude here.
  let height_raw = read_u32_le(data, 22)
  let height = if height_raw < 0 { -height_raw } else { height_raw }
  (width, height, ImageFormat::BMP)
}

///|
/// Read QOI dimensions from header
fn qoi_dimensions(data : Bytes) -> (Int, Int, ImageFormat) raise Failure {
  if data.length() < 14 {
    raise Failure::Failure("QOI: file too small for header reading")
  }
  let width = read_u32_be(data, 4)
  let height = read_u32_be(data, 8)
  (width, height, ImageFormat::QOI)
}

///|
/// Read TGA dimensions from header
fn tga_dimensions(data : Bytes) -> (Int, Int, ImageFormat) raise Failure {
  if data.length() < 18 {
    raise Failure::Failure("TGA: file too small for header reading")
  }
  let width = read_u16_le(data, 12)
  let height = read_u16_le(data, 14)
  (width, height, ImageFormat::TGA)
}

///|
/// Read GIF dimensions from header
fn gif_dimensions(data : Bytes) -> (Int, Int, ImageFormat) raise Failure {
  if data.length() < 10 {
    raise Failure::Failure("GIF: file too small for header reading")
  }
  let width = read_u16_le(data, 6)
  let height = read_u16_le(data, 8)
  (width, height, ImageFormat::GIF)
}

///|
/// Read PNG dimensions from IHDR chunk (fast, only parses the first chunk)
fn png_dimensions(data : Bytes) -> (Int, Int, ImageFormat) raise Failure {
  // PNG: 8-byte signature + 4-byte length + 4-byte "IHDR" + 13-byte IHDR data
  if data.length() < 33 {
    raise Failure::Failure("PNG: file too small for IHDR reading")
  }
  // Skip signature (8), read length (4), verify "IHDR" (4)
  if data[12] != b'I' ||
    data[13] != b'H' ||
    data[14] != b'D' ||
    data[15] != b'R' {
    raise Failure::Failure("PNG: first chunk is not IHDR")
  }
  let width = read_u32_be(data, 16)
  let height = read_u32_be(data, 20)
  (width, height, ImageFormat::PNG)
}

//-----------------------------------------------------------------------------
// Convenience Functions
//-----------------------------------------------------------------------------

///|
/// Get a human-readable string for a pixel format
pub fn pixel_format_name(format : PixelFormat) -> String {
  match format {
    PixelFormat::Gray8 => "Gray8"
    PixelFormat::GrayA8 => "GrayA8"
    PixelFormat::RGB8 => "RGB8"
    PixelFormat::RGBA8 => "RGBA8"
  }
}

///|
/// Get a human-readable string for an image format
pub fn image_format_name(format : ImageFormat) -> String {
  match format {
    ImageFormat::BMP => "BMP"
    ImageFormat::QOI => "QOI"
    ImageFormat::TGA => "TGA"
    ImageFormat::PNG => "PNG"
    ImageFormat::GIF => "GIF"
    ImageFormat::JPEG => "JPEG"
    ImageFormat::ICO => "ICO"
    ImageFormat::TIFF => "TIFF"
    ImageFormat::FIM => "FIM"
  }
}

//-----------------------------------------------------------------------------
// Unified Encode API
//-----------------------------------------------------------------------------

///|
/// Encode an image to the specified format. Currently BMP and QOI have
/// encoders; other formats raise `DecodeError::EncodeNotImplemented`.
pub fn encode(img : Image, format : ImageFormat) -> Bytes raise DecodeError {
  match format {
    ImageFormat::BMP =>
      match (try? encode_bmp(img)) {
        Ok(bytes) => bytes
        Err(Failure::Failure(msg)) => raise DecodeError::InvalidHeader(msg)
      }
    ImageFormat::QOI =>
      match (try? encode_qoi(img)) {
        Ok(bytes) => bytes
        Err(Failure::Failure(msg)) => raise DecodeError::InvalidHeader(msg)
      }
    _ =>
      raise DecodeError::EncodeNotImplemented(
        "encoding not yet supported for " + image_format_name(format),
      )
  }
}
