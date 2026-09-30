// Copyright (c) 2025 lws
// ICO / CUR container decoder for MoonBit - delegates inner image
// data to the existing BMP / PNG codecs.
//
// File layout (Windows .ico):
//
//   ICONDIR (6 bytes)
//     uint16 reserved        // always 0
//     uint16 image_type      // 1 = ICO, 2 = CUR (cursor)
//     uint16 num_images
//
//   ICONDIRENTRY[num_images] (16 bytes each)
//     uint8  width           // 0 means 256
//     uint8  height          // 0 means 256
//     uint8  color_count     // 0 if more than 256 colours
//     uint8  reserved
//     uint16 planes          // 0 or 1
//     uint16 bit_count
//     uint32 bytes_in_res
//     uint32 image_offset    // byte offset into the file
//
//   image_data[num_images]
//     either a full BMP file (including the 14-byte "BM" header),
//     a full PNG file (8-byte PNG signature + chunks),
//     or a DIB-only BMP (no file header, just the BITMAPINFOHEADER +
//     pixel data — the form Windows actually writes for Vista+ icons
//     that are >= 32bpp is the PNG form).
//
// `decode_ico` picks the largest icon (by area, falling back to first
// if there is a tie) and dispatches its inner bytes to decode_bmp or
// decode_png. For DIB-only entries we prepend a synthetic BMP file
// header so the existing BMP decoder can handle them.

///|
/// Decode an ICO / CUR container, returning the largest available
/// image. CUR is accepted but its hotspot metadata is discarded — the
/// cursor is returned as a plain image.
pub fn decode_ico(data : Bytes) -> Image raise Failure {
  // ICONDIR header
  if data.length() < 6 {
    raise Failure::Failure("ICO: too short for header")
  }
  let reserved = read_u16_le(data, 0)
  let icon_type = read_u16_le(data, 2)
  let count = read_u16_le(data, 4)
  if reserved != 0 {
    raise Failure::Failure("ICO: reserved field must be 0")
  }
  if icon_type != 1 && icon_type != 2 {
    raise Failure::Failure("ICO: unsupported type (only ICO/CUR supported)")
  }
  if count == 0 {
    raise Failure::Failure("ICO: zero entries")
  }
  if data.length() < 6 + count * 16 {
    raise Failure::Failure("ICO: truncated directory")
  }

  // Pick the largest entry (by width × height). Width/height = 0 means
  // 256 per the spec, so substitute before computing area.
  let mut best = -1
  let mut best_area = -1
  for i = 0; i < count; i = i + 1 {
    let off = 6 + i * 16
    let w_raw = data[off].to_int()
    let h_raw = data[off + 1].to_int()
    let aw = if w_raw == 0 { 256 } else { w_raw }
    let ah = if h_raw == 0 { 256 } else { h_raw }
    let area = aw * ah
    if area > best_area {
      best_area = area
      best = i
    }
  }
  let entry_off = 6 + best * 16
  let bytes_in_res = read_u32_le(data, entry_off + 8)
  let image_offset = read_u32_le(data, entry_off + 12)
  if image_offset + bytes_in_res > data.length() {
    raise Failure::Failure("ICO: image data out of bounds")
  }
  if bytes_in_res < 4 {
    raise Failure::Failure("ICO: image payload too small")
  }
  let inner = data[image_offset:image_offset + bytes_in_res].to_owned()

  // Detect the inner format and dispatch.
  if inner[0] == b'B' && inner[1] == b'M' {
    // Full BMP file
    decode_bmp(inner)
  } else if inner.length() >= 8 &&
    inner[0] == b'\x89' &&
    inner[1] == b'P' &&
    inner[2] == b'N' &&
    inner[3] == b'G' {
    // Full PNG file
    decode_png(inner)
  } else if inner[0] == b'\x28' {
    // DIB-only BMP (BITMAPINFOHEADER starts with the dib_size field,
    // which is always 40 for the simple ICO case; some older 16-bit
    // icons use BITMAPCOREHEADER = 12. We synthesise a file header
    // that points to the right pixel-data offset so decode_bmp works.)
    let dib_size = read_u32_le(inner, 0)
    if dib_size < 12 {
      raise Failure::Failure("ICO: bad DIB header size")
    }
    let header_size = 14
    let data_offset = header_size + dib_size
    let file_size = header_size + inner.length()
    let synth = build_bmp_file_header(file_size, data_offset)
    let full = concat_bytes(synth, inner)
    decode_bmp(full)
  } else {
    raise Failure::Failure("ICO: unrecognised inner image format")
  }
}

///|
/// Construct the 14-byte BMP file header:
///
///   char[2]  "BM"
///   uint32   file_size
///   uint16   reserved1 (= 0)
///   uint16   reserved2 (= 0)
///   uint32   data_offset  (where pixel data starts in the file)
///
/// All values written little-endian.
fn build_bmp_file_header(file_size : Int, data_offset : Int) -> Bytes {
  let b0 = file_size & 0xFF
  let b1 = (file_size >> 8) & 0xFF
  let b2 = (file_size >> 16) & 0xFF
  let b3 = (file_size >> 24) & 0xFF
  let o0 = data_offset & 0xFF
  let o1 = (data_offset >> 8) & 0xFF
  let o2 = (data_offset >> 16) & 0xFF
  let o3 = (data_offset >> 24) & 0xFF
  Bytes::from_array([
    b'B',
    b'M',
    b0.to_byte(),
    b1.to_byte(),
    b2.to_byte(),
    b3.to_byte(),
    b'\x00',
    b'\x00', // reserved1
    b'\x00',
    b'\x00', // reserved2
    o0.to_byte(),
    o1.to_byte(),
    o2.to_byte(),
    o3.to_byte(),
  ])
}

///|
/// Concatenate two byte sequences into one new Bytes value.
fn concat_bytes(a : Bytes, b : Bytes) -> Bytes {
  let arr = Array::make(a.length() + b.length(), b'\x00')
  for i = 0; i < a.length(); i = i + 1 {
    arr[i] = a[i]
  }
  for i = 0; i < b.length(); i = i + 1 {
    arr[a.length() + i] = b[i]
  }
  Bytes::from_array(arr)
}