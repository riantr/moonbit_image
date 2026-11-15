// Round-trip and property tests for the encoders.
//
// The encoders are checked against the package's own decoders: an
// encode/decode round trip must reproduce the pixels exactly. That
// catches a whole class of encoder bugs (wrong stride, wrong colour
// order, broken chunk CRC, broken filter) without needing an external
// reference implementation in the test suite.
//
// Cross-implementation comparison against `mizchi/image` lives outside
// the package, in `.tools/cross_check_encoders.py`, so that this
// package keeps its "zero external runtime dependencies" property.

//-----------------------------------------------------------------------------
// Helpers
//-----------------------------------------------------------------------------

///|
/// A deterministic RGBA8 test image: `width` x `height`, with each
/// channel derived from the pixel position so that neighbouring pixels
/// differ and a filter/stride mistake is visible.
fn synth_rgba8(width : Int32, height : Int32) -> Image {
  let buf = Array::make(width * height * 4, b'\x00')
  for y = 0; y < height; y = y + 1 {
    for x = 0; x < width; x = x + 1 {
      let i = (y * width + x) * 4
      buf[i] = ((x * 7 + y * 3) % 256).to_byte()
      buf[i + 1] = ((x * 11 + y * 5) % 256).to_byte()
      buf[i + 2] = ((x * 13 + y * 17) % 256).to_byte()
      buf[i + 3] = ((x * 19 + y * 23) % 256).to_byte()
    }
  }
  Image::new(width, height, PixelFormat::RGBA8, Bytes::from_array(buf))
}

///|
/// A deterministic Gray8 test image.
fn synth_gray8(width : Int32, height : Int32) -> Image {
  let buf = Array::make(width * height, b'\x00')
  for y = 0; y < height; y = y + 1 {
    for x = 0; x < width; x = x + 1 {
      buf[y * width + x] = ((x * 5 + y * 9) % 256).to_byte()
    }
  }
  Image::new(width, height, PixelFormat::Gray8, Bytes::from_array(buf))
}

///|
/// A numeric code for a pixel format, so that two formats can be
/// compared without `PixelFormat` deriving `Eq`.
fn format_code(format : PixelFormat) -> Int32 {
  match format {
    PixelFormat::Gray8 => 0
    PixelFormat::GrayA8 => 1
    PixelFormat::RGB8 => 2
    PixelFormat::RGBA8 => 3
  }
}

///|
/// Assert that two images have the same dimensions, format and pixels.
fn assert_same_image(actual : Image, expected : Image) -> Unit raise Error {
  assert_eq(actual.width, expected.width)
  assert_eq(actual.height, expected.height)
  assert_eq(format_code(actual.format), format_code(expected.format))
  assert_eq(actual.data.length(), expected.data.length())
  assert_eq(actual.data, expected.data)
}

//-----------------------------------------------------------------------------
// PNG
//-----------------------------------------------------------------------------

///|
test "png: encode produces the 8-byte PNG signature" {
  let img = synth_rgba8(4, 4)
  let bytes = encode_png(img) catch { _ => fail("encode_png raised") }
  assert_true(bytes.length() > 8)
  assert_eq(bytes[0], b'\x89')
  assert_eq(bytes[1], b'P')
  assert_eq(bytes[2], b'N')
  assert_eq(bytes[3], b'G')
}

///|
test "png: encode/decode round trip preserves RGBA8 pixels" {
  let img = synth_rgba8(17, 13)
  let bytes = encode_png(img) catch { _ => fail("encode_png raised") }
  let decoded = decode_png(bytes) catch { _ => fail("decode_png raised") }
  assert_same_image(decoded, img)
}

///|
test "png: encode/decode round trip preserves Gray8 pixels" {
  let img = synth_gray8(9, 7)
  let bytes = encode_png(img) catch { _ => fail("encode_png raised") }
  let decoded = decode_png(bytes) catch { _ => fail("decode_png raised") }
  assert_same_image(decoded, img)
}

///|
test "png: a 1x1 image round trips" {
  let img = Image::new(1, 1, PixelFormat::RGBA8, b"\x01\x02\x03\x04")
  let bytes = encode_png(img) catch { _ => fail("encode_png raised") }
  let decoded = decode_png(bytes) catch { _ => fail("decode_png raised") }
  assert_same_image(decoded, img)
}

///|
test "png: the encoder compresses a uniform image" {
  // A 64x64 opaque white image is highly compressible; without real
  // compression the output would be about 16 KiB of raw pixels.
  let buf = Array::make(64 * 64 * 4, b'\xFF')
  let img = Image::new(64, 64, PixelFormat::RGBA8, Bytes::from_array(buf))
  let bytes = encode_png(img) catch { _ => fail("encode_png raised") }
  assert_true(bytes.length() < 1024)
}

///|
test "png: IHDR carries the dimensions and colour type" {
  let img = synth_gray8(5, 3)
  let bytes = encode_png(img) catch { _ => fail("encode_png raised") }
  // 8 byte signature, then a 4 byte length, then "IHDR".
  assert_eq(bytes[12], b'I')
  assert_eq(bytes[13], b'H')
  assert_eq(bytes[14], b'D')
  assert_eq(bytes[15], b'R')
  // Width and height are big-endian u32 after the type.
  assert_eq(bytes[16], 0)
  assert_eq(bytes[17], 0)
  assert_eq(bytes[18], 0)
  assert_eq(bytes[19], 5)
  assert_eq(bytes[23], 3)
  // Bit depth 8, colour type 0 (greyscale).
  assert_eq(bytes[24], 8)
  assert_eq(bytes[25], 0)
}

///|
test "png: every chunk CRC is valid" {
  let img = synth_rgba8(6, 6)
  let bytes = encode_png(img) catch { _ => fail("encode_png raised") }
  // Walk the chunk list and verify each CRC.
  let mut pos = 8
  let mut chunks = 0
  while pos + 12 <= bytes.length() {
    let len = (bytes[pos].to_int() << 24) |
      (bytes[pos + 1].to_int() << 16) |
      (bytes[pos + 2].to_int() << 8) |
      bytes[pos + 3].to_int()
    let type_bytes = Bytes::from_array([
      bytes[pos + 4],
      bytes[pos + 5],
      bytes[pos + 6],
      bytes[pos + 7],
    ])
    // Rebuild the payload as a standalone array so that the CRC can be
    // computed over exactly the bytes the file stores.
    let payload = Array::make(len, b'\x00')
    for i = 0; i < len; i = i + 1 {
      payload[i] = bytes[pos + 8 + i]
    }
    let stored = (bytes[pos + 8 + len].to_int() << 24) |
      (bytes[pos + 9 + len].to_int() << 16) |
      (bytes[pos + 10 + len].to_int() << 8) |
      bytes[pos + 11 + len].to_int()
    assert_eq(crc32_chunk(type_bytes, Bytes::from_array(payload)), stored)
    pos = pos + 12 + len
    chunks = chunks + 1
  }
  // IHDR + IDAT + IEND
  assert_eq(chunks, 3)
  assert_eq(pos, bytes.length())
}

///|
test "png: encode rejects a zero-sized image" {
  let img = Image::new(0, 4, PixelFormat::RGBA8, b"")
  let res : Result[Bytes, Failure] = Ok(encode_png(img)) catch { e => Err(e) }
  match res {
    Err(_) => assert_true(true)
    Ok(_) => fail("encode_png accepted a zero-sized image")
  }
}

//-----------------------------------------------------------------------------
// TGA
//-----------------------------------------------------------------------------

///|
test "tga: encode/decode round trip preserves RGBA8 pixels" {
  let img = synth_rgba8(11, 7)
  let bytes = encode_tga(img) catch { _ => fail("encode_tga raised") }
  let decoded = decode_tga(bytes) catch { _ => fail("decode_tga raised") }
  assert_eq(decoded.width, 11)
  assert_eq(decoded.height, 7)
  assert_eq(format_code(decoded.format), format_code(PixelFormat::RGBA8))
  assert_eq(decoded.data, img.data)
}

///|
test "tga: RLE encode/decode round trip preserves RGBA8 pixels" {
  let img = synth_rgba8(11, 7)
  let bytes = encode_tga_rle(img) catch { _ => fail("encode_tga_rle raised") }
  let decoded = decode_tga(bytes) catch { _ => fail("decode_tga raised") }
  assert_eq(decoded.width, 11)
  assert_eq(decoded.height, 7)
  assert_eq(decoded.data, img.data)
}

///|
test "tga: the header carries the type, size and depth" {
  let img = synth_rgba8(4, 3)
  let bytes = encode_tga(img) catch { _ => fail("encode_tga raised") }
  assert_eq(bytes[2], 2) // uncompressed true-color
  assert_eq(bytes[12], 4) // width, little-endian
  assert_eq(bytes[14], 3) // height, little-endian
  assert_eq(bytes[16], 32) // 32 bits per pixel (the image has alpha)
  assert_eq(bytes[17], 0x28) // top-to-bottom, 8 attribute bits
}

///|
test "tga: a greyscale image is written as type 3 with 8-bit samples" {
  let img = synth_gray8(5, 4)
  let bytes = encode_tga(img) catch { _ => fail("encode_tga raised") }
  assert_eq(bytes[2], 3) // uncompressed greyscale
  assert_eq(bytes[16], 8) // 8 bits per pixel
  let decoded = decode_tga(bytes) catch { _ => fail("decode_tga raised") }
  assert_eq(format_code(decoded.format), format_code(PixelFormat::Gray8))
  assert_eq(decoded.data, img.data)
}

///|
test "tga: an opaque image is written as 24-bit BGR" {
  let buf = Array::make(4 * 4 * 4, b'\xFF')
  let img = Image::new(4, 4, PixelFormat::RGBA8, Bytes::from_array(buf))
  let bytes = encode_tga(img) catch { _ => fail("encode_tga raised") }
  assert_eq(bytes[16], 24)
}

///|
test "tga: RLE compresses a flat image" {
  let buf = Array::make(32 * 32 * 4, b'\x00')
  let img = Image::new(32, 32, PixelFormat::RGBA8, Bytes::from_array(buf))
  let plain = encode_tga(img) catch { _ => fail("encode_tga raised") }
  let rle = encode_tga_rle(img) catch { _ => fail("encode_tga_rle raised") }
  assert_eq(rle[2], 10) // RLE true-color
  assert_true(rle.length() < plain.length())
}

///|
test "tga: encode rejects a zero-sized image" {
  let img = Image::new(0, 4, PixelFormat::RGBA8, b"")
  let res : Result[Bytes, Failure] = Ok(encode_tga(img)) catch { e => Err(e) }
  match res {
    Err(_) => assert_true(true)
    Ok(_) => fail("encode_tga accepted a zero-sized image")
  }
}

//-----------------------------------------------------------------------------
// GIF
//-----------------------------------------------------------------------------

///|
/// A deterministic RGBA8 image with only a handful of colours, so that
/// the GIF palette can hold them all exactly.
fn synth_few_colors(width : Int32, height : Int32) -> Image {
  let buf = Array::make(width * height * 4, b'\x00')
  for y = 0; y < height; y = y + 1 {
    for x = 0; x < width; x = x + 1 {
      let i = (y * width + x) * 4
      let k = (x + y) % 4
      buf[i] = (k * 60).to_byte()
      buf[i + 1] = (k * 30).to_byte()
      buf[i + 2] = (k * 90).to_byte()
      buf[i + 3] = b'\xFF'
    }
  }
  Image::new(width, height, PixelFormat::RGBA8, Bytes::from_array(buf))
}

///|
test "gif: encode produces a GIF89a header and trailer" {
  let img = synth_few_colors(4, 4)
  let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
  assert_eq(bytes[0], b'G')
  assert_eq(bytes[1], b'I')
  assert_eq(bytes[2], b'F')
  assert_eq(bytes[3], b'8')
  assert_eq(bytes[4], b'9')
  assert_eq(bytes[5], b'a')
  assert_eq(bytes[bytes.length() - 1], b'\x3B')
}

///|
test "gif: encode/decode round trip preserves pixels" {
  let img = synth_few_colors(13, 9)
  let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
  let decoded = decode_gif(bytes) catch { _ => fail("decode_gif raised") }
  assert_eq(decoded.width, 13)
  assert_eq(decoded.height, 9)
  assert_eq(decoded.data, img.data)
}

///|
test "gif: a 1x1 image round trips" {
  let img = Image::new(1, 1, PixelFormat::RGBA8, b"\x11\x22\x33\xFF")
  let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
  let decoded = decode_gif(bytes) catch { _ => fail("decode_gif raised") }
  assert_eq(decoded.width, 1)
  assert_eq(decoded.height, 1)
  assert_eq(decoded.data, img.data)
}

///|
test "gif: transparency survives the round trip" {
  // The top-left 2x2 block is fully transparent, the rest is opaque.
  let buf = Array::make(4 * 4 * 4, b'\xFF')
  for i = 0; i < 4; i = i + 1 {
    buf[i * 4] = b'\x00'
    buf[i * 4 + 1] = b'\x00'
    buf[i * 4 + 2] = b'\x00'
    buf[i * 4 + 3] = b'\x00'
  }
  let img = Image::new(4, 4, PixelFormat::RGBA8, Bytes::from_array(buf))
  let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
  let decoded = decode_gif(bytes) catch { _ => fail("decode_gif raised") }
  assert_eq(decoded.width, 4)
  assert_eq(decoded.height, 4)
  // The transparent block must come back fully transparent.
  for i = 0; i < 4; i = i + 1 {
    assert_eq(decoded.data[i * 4 + 3], b'\x00')
  }
  // The opaque block must come back opaque and unchanged.
  for i = 4; i < 16; i = i + 1 {
    assert_eq(decoded.data[i * 4], b'\xFF')
    assert_eq(decoded.data[i * 4 + 3], b'\xFF')
  }
}

///|
/// A deterministic RGBA8 image with many distinct colours and full
/// opacity, so that the GIF palette has to quantise it.
fn synth_opaque_many(width : Int32, height : Int32) -> Image {
  let buf = Array::make(width * height * 4, b'\x00')
  for y = 0; y < height; y = y + 1 {
    for x = 0; x < width; x = x + 1 {
      let i = (y * width + x) * 4
      buf[i] = ((x * 29 + y * 7) % 256).to_byte()
      buf[i + 1] = ((x * 13 + y * 41) % 256).to_byte()
      buf[i + 2] = ((x * 57 + y * 11) % 256).to_byte()
      buf[i + 3] = b'\xFF'
    }
  }
  Image::new(width, height, PixelFormat::RGBA8, Bytes::from_array(buf))
}

///|
test "gif: an image with few colours keeps them exactly" {
  let img = synth_few_colors(16, 16)
  let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
  let decoded = decode_gif(bytes) catch { _ => fail("decode_gif raised") }
  assert_eq(decoded.data, img.data)
}

///|
test "gif: an image with many colours is quantised, not rejected" {
  // 32x32 with 1024 distinct colours: the palette can only hold 256 of
  // them, so the encoder has to quantise.
  let img = synth_opaque_many(32, 32)
  let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
  let decoded = decode_gif(bytes) catch { _ => fail("decode_gif raised") }
  assert_eq(decoded.width, 32)
  assert_eq(decoded.height, 32)
  // The quantised result must still be close to the original.
  let orig = img.data
  let mut worst = 0
  let mut i = 0
  while i < 32 * 32 {
    let dr = orig[i * 4].to_int() - decoded.data[i * 4].to_int()
    let dg = orig[i * 4 + 1].to_int() - decoded.data[i * 4 + 1].to_int()
    let db = orig[i * 4 + 2].to_int() - decoded.data[i * 4 + 2].to_int()
    let d = dr * dr + dg * dg + db * db
    if d > worst {
      worst = d
    }
    i = i + 1
  }
  assert_true(worst < 20000)
}

///|
test "gif: encode rejects a zero-sized image" {
  let img = Image::new(0, 4, PixelFormat::RGBA8, b"")
  let res : Result[Bytes, Failure] = Ok(encode_gif(img)) catch { e => Err(e) }
  match res {
    Err(_) => assert_true(true)
    Ok(_) => fail("encode_gif accepted a zero-sized image")
  }
}

//-----------------------------------------------------------------------------
// TGA decoder: the RLE packet semantics
//-----------------------------------------------------------------------------

///|
/// A hand-built 4x1 32-bit TGA with one run packet and one raw packet.
///
/// The Truevision TGA v2.0 packet rules are:
///   - bit 7 of the packet header SET   -> run-length packet, the pixel
///     that follows is repeated
///   - bit 7 of the packet header CLEAR -> raw packet, the pixels follow
///
/// This fixture is written out byte by byte rather than produced by the
/// encoder, so that an encoder and a decoder that agree on the wrong
/// bit cannot hide behind each other.
fn tga_rle_fixture() -> Bytes {
  let buf = Array::make(18 + 4 * 4 + 4, b'\x00')
  // Header: type 10 (RLE true-color), 4x1, 32 bits per pixel, top origin.
  buf[2] = 10
  buf[12] = 4 // width
  buf[14] = 1 // height
  buf[16] = 32
  buf[17] = 0x28
  // Run-length packet: repeat the following pixel twice. Header 0x81
  // means bit 7 set ("repeat") and count = 1 + 1 = 2.
  buf[18] = 0x81
  buf[19] = 0x11 // B
  buf[20] = 0x22 // G
  buf[21] = 0x33 // R
  buf[22] = 0x44 // A
  // Raw packet: two pixels follow verbatim. Header 0x01 means bit 7
  // clear ("copy") and count = 1 + 1 = 2.
  buf[23] = 0x01
  buf[24] = 0x55
  buf[25] = 0x66
  buf[26] = 0x77
  buf[27] = 0x88
  buf[28] = 0x99
  buf[29] = 0xAA
  buf[30] = 0xBB
  buf[31] = 0xCC
  Bytes::from_array(buf)
}

///|
test "tga: decode_tga reads run and raw packets with the right semantics" {
  let img = decode_tga(tga_rle_fixture()) catch {
    _ => fail("decode_tga raised on the RLE fixture")
  }
  assert_eq(img.width, 4)
  assert_eq(img.height, 1)
  // The first two pixels are the repeated one.
  for i = 0; i < 2; i = i + 1 {
    assert_eq(img.data[i * 4], 0x33) // R
    assert_eq(img.data[i * 4 + 1], 0x22) // G
    assert_eq(img.data[i * 4 + 2], 0x11) // B
    assert_eq(img.data[i * 4 + 3], 0x44) // A
  }
  // The last one comes from the raw packet.
  assert_eq(img.data[12], 0xBB) // R
  assert_eq(img.data[13], 0xAA) // G
  assert_eq(img.data[14], 0x99) // B
  assert_eq(img.data[15], 0xCC) // A
}

//-----------------------------------------------------------------------------
// JPEG
//-----------------------------------------------------------------------------

///|
/// A deterministic RGB8 test image.
fn synth_rgb8(width : Int32, height : Int32) -> Image {
  let buf = Array::make(width * height * 3, b'\x00')
  for y = 0; y < height; y = y + 1 {
    for x = 0; x < width; x = x + 1 {
      let i = (y * width + x) * 3
      buf[i] = ((x * 23 + y * 3) % 256).to_byte()
      buf[i + 1] = ((x * 7 + y * 41) % 256).to_byte()
      buf[i + 2] = ((x * 53 + y * 17) % 256).to_byte()
    }
  }
  Image::new(width, height, PixelFormat::RGB8, Bytes::from_array(buf))
}

///|
/// The RGB channels of an RGBA8 image, as an RGB8 image.
fn strip_alpha(rgba : Image) -> Image {
  let count = rgba.width * rgba.height
  let buf = Array::make(count * 3, b'\x00')
  let mut i = 0
  while i < count {
    buf[i * 3] = rgba.data[i * 4]
    buf[i * 3 + 1] = rgba.data[i * 4 + 1]
    buf[i * 3 + 2] = rgba.data[i * 4 + 2]
    i = i + 1
  }
  Image::new(rgba.width, rgba.height, PixelFormat::RGB8, Bytes::from_array(buf))
}

///|
/// The absolute difference of two bytes.
fn byte_diff(a : Byte, b : Byte) -> Int32 {
  let d = a.to_int() - b.to_int()
  if d < 0 {
    -d
  } else {
    d
  }
}

///|
/// The largest per-channel difference between two RGB8 images.
fn max_rgb_difference(a : Image, b : Image) -> Int32 {
  let mut worst = 0
  let mut i = 0
  let count = a.width * a.height
  while i < count {
    let dr = byte_diff(a.data[i * 3], b.data[i * 3])
    let dg = byte_diff(a.data[i * 3 + 1], b.data[i * 3 + 1])
    let db = byte_diff(a.data[i * 3 + 2], b.data[i * 3 + 2])
    if dr > worst {
      worst = dr
    }
    if dg > worst {
      worst = dg
    }
    if db > worst {
      worst = db
    }
    i = i + 1
  }
  worst
}

///|
/// The index of the first occurrence of the two-byte marker, or -1.
fn jpeg_find_marker(bytes : Bytes, marker : Int32) -> Int32 {
  let mut i = 0
  while i + 1 < bytes.length() {
    if bytes[i].to_int() == 0xFF && bytes[i + 1].to_int() == marker {
      return i
    }
    i = i + 1
  }
  -1
}

///|
test "jpeg: encode produces a file that starts with SOI and ends with EOI" {
  let img = synth_rgb8(8, 8)
  let bytes = encode_jpeg(img, 85) catch { _ => fail("encode_jpeg raised") }
  assert_true(bytes.length() > 100)
  assert_eq(bytes[0], b'\xFF')
  assert_eq(bytes[1], b'\xD8')
  assert_eq(bytes[bytes.length() - 2], b'\xFF')
  assert_eq(bytes[bytes.length() - 1], b'\xD9')
}

///|
test "jpeg: encode writes the JFIF, quantisation, frame and scan segments" {
  let img = synth_rgb8(8, 8)
  let bytes = encode_jpeg(img, 85) catch { _ => fail("encode_jpeg raised") }
  // APP0/JFIF.
  let app0 = jpeg_find_marker(bytes, 0xE0)
  assert_true(app0 >= 0)
  assert_eq(bytes[app0 + 4], b'J')
  assert_eq(bytes[app0 + 5], b'F')
  assert_eq(bytes[app0 + 6], b'I')
  assert_eq(bytes[app0 + 7], b'F')
  // DQT, SOF0, DHT and SOS must all be present, and in that order.
  let dqt = jpeg_find_marker(bytes, 0xDB)
  let sof0 = jpeg_find_marker(bytes, 0xC0)
  let dht = jpeg_find_marker(bytes, 0xC4)
  let sos = jpeg_find_marker(bytes, 0xDA)
  assert_true(dqt > 0 && sof0 > dqt && dht > sof0 && sos > dht)
}

///|
test "jpeg: the frame header carries the right dimensions and 4:4:4 sampling" {
  let img = synth_rgb8(13, 7)
  let bytes = encode_jpeg(img, 85) catch { _ => fail("encode_jpeg raised") }
  let sof0 = jpeg_find_marker(bytes, 0xC0)
  assert_true(sof0 > 0)
  // The segment length, then the precision, then the height and the
  // width as big-endian u16.
  assert_eq(bytes[sof0 + 4], b'\x08') // 8-bit precision
  assert_eq(bytes[sof0 + 5], 0) // height high byte
  assert_eq(bytes[sof0 + 6], 7) // height low byte
  assert_eq(bytes[sof0 + 7], 0) // width high byte
  assert_eq(bytes[sof0 + 8], 13) // width low byte
  assert_eq(bytes[sof0 + 9], 3) // three components
  // Every component uses a 1x1 sampling factor.
  let mut i = 0
  while i < 3 {
    assert_eq(bytes[sof0 + 11 + i * 3], 0x11)
    i = i + 1
  }
}

///|
test "jpeg: a solid colour image round trips almost exactly" {
  // A uniform block has only a DC coefficient, so the only loss is the
  // quantisation of that coefficient.
  let buf = Array::make(16 * 16 * 4, b'\x00')
  for i = 0; i < 16 * 16; i = i + 1 {
    buf[i * 4] = b'\xC8' // 200
    buf[i * 4 + 1] = b'\x64' // 100
    buf[i * 4 + 2] = b'\x32' // 50
    buf[i * 4 + 3] = b'\xFF'
  }
  let img = Image::new(16, 16, PixelFormat::RGBA8, Bytes::from_array(buf))
  let bytes = encode_jpeg(img, 95) catch { _ => fail("encode_jpeg raised") }
  let decoded = decode_jpeg(bytes) catch { _ => fail("decode_jpeg raised") }
  assert_eq(decoded.width, 16)
  assert_eq(decoded.height, 16)
  assert_eq(format_code(decoded.format), format_code(PixelFormat::RGB8))
  let diff = max_rgb_difference(decoded, strip_alpha(img))
  assert_true(diff <= 6)
}

///|
/// Assert that two RGB8 images differ by at most `tolerance` in every
/// channel, reporting the actual difference when they do not.
fn assert_rgb_close(
  actual : Image,
  expected : Image,
  tolerance : Int32,
) -> Unit raise Error {
  let diff = max_rgb_difference(actual, expected)
  if diff > tolerance {
    fail("RGB difference \{diff} exceeds the tolerance of \{tolerance}")
  }
}

///|
/// An asymmetric 8x8 image, so that a transposed block is unmistakable:
/// every pixel differs from its mirror across the block diagonal.
fn synth_asymmetric_8x8() -> Image {
  let buf = Array::make(8 * 8 * 4, b'\x00')
  for y = 0; y < 8; y = y + 1 {
    for x = 0; x < 8; x = x + 1 {
      let i = (y * 8 + x) * 4
      buf[i] = (x * 30).to_byte()
      buf[i + 1] = (y * 30).to_byte()
      buf[i + 2] = ((x + y) * 15).to_byte()
      buf[i + 3] = b'\xFF'
    }
  }
  Image::new(8, 8, PixelFormat::RGBA8, Bytes::from_array(buf))
}

///|
test "jpeg: the decoder does not transpose the 8x8 blocks" {
  // The IDCT used to leave every block transposed. On a uniform block
  // that is invisible, so the check compares the decoded pixels with
  // the source AND with the transposed source: only the first can
  // match.
  let img = synth_asymmetric_8x8()
  let bytes = encode_jpeg(img, 95) catch { _ => fail("encode_jpeg raised") }
  let decoded = decode_jpeg(bytes) catch { _ => fail("decode_jpeg raised") }
  let source = strip_alpha(img)
  let mut straight = 0
  let mut transposed = 0
  let mut y = 0
  while y < 8 {
    let mut x = 0
    while x < 8 {
      let di = (y * 8 + x) * 3
      let si = (y * 8 + x) * 3
      let ti = (x * 8 + y) * 3
      straight = straight + byte_diff(decoded.data[di], source.data[si])
      transposed = transposed + byte_diff(decoded.data[di], source.data[ti])
      x = x + 1
    }
    y = y + 1
  }
  // The straight comparison must be the small one.
  assert_true(straight < 400)
  assert_true(transposed > 4000)
}

///|
/// A smooth RGB8 gradient: the kind of content a JPEG codec is
/// actually meant for, so the round trip has to be nearly exact.
fn synth_gradient_rgb8(width : Int32, height : Int32) -> Image {
  let buf = Array::make(width * height * 3, b'\x00')
  for y = 0; y < height; y = y + 1 {
    for x = 0; x < width; x = x + 1 {
      let i = (y * width + x) * 3
      buf[i] = (x * 255 / (if width > 1 { width - 1 } else { 1 })).to_byte()
      buf[i + 1] = (y * 255 / (if height > 1 { height - 1 } else { 1 })).to_byte()
      buf[i + 2] = ((x + y) *
      255 /
      (if width + height > 2 { width + height - 2 } else { 1 })).to_byte()
    }
  }
  Image::new(width, height, PixelFormat::RGB8, Bytes::from_array(buf))
}

///|
test "jpeg: encode/decode round trip keeps the dimensions and stays close" {
  let img = synth_gradient_rgb8(19, 11)
  let bytes = encode_jpeg(img, 90) catch { _ => fail("encode_jpeg raised") }
  let decoded = decode_jpeg(bytes) catch { _ => fail("decode_jpeg raised") }
  assert_eq(decoded.width, 19)
  assert_eq(decoded.height, 11)
  assert_eq(decoded.data.length(), 19 * 11 * 3)
  assert_rgb_close(decoded, img, 8)
}

///|
test "jpeg: an image whose size is not a multiple of 8 still round trips" {
  // The encoder has to pad the last block of each edge by replicating
  // the border pixels.
  let img = synth_gradient_rgb8(13, 5)
  let bytes = encode_jpeg(img, 90) catch { _ => fail("encode_jpeg raised") }
  let decoded = decode_jpeg(bytes) catch { _ => fail("decode_jpeg raised") }
  assert_eq(decoded.width, 13)
  assert_eq(decoded.height, 5)
  assert_rgb_close(decoded, img, 8)
}

///|
test "jpeg: high frequency noise is quantised, not corrupted" {
  // Pseudo-random pixels are the worst case for a DCT codec: most of
  // the energy lands in the high frequencies, which the quantisation
  // tables throw away. The result is lossy but it must still look like
  // the same image.
  let img = synth_rgb8(16, 16)
  let bytes = encode_jpeg(img, 90) catch { _ => fail("encode_jpeg raised") }
  let decoded = decode_jpeg(bytes) catch { _ => fail("decode_jpeg raised") }
  assert_eq(decoded.width, 16)
  assert_eq(decoded.height, 16)
  assert_rgb_close(decoded, img, 48)
}

///|
test "jpeg: a 1x1 image round trips" {
  let img = Image::new(1, 1, PixelFormat::RGBA8, b"\x11\x22\x33\xFF")
  let bytes = encode_jpeg(img, 95) catch { _ => fail("encode_jpeg raised") }
  let decoded = decode_jpeg(bytes) catch { _ => fail("decode_jpeg raised") }
  assert_eq(decoded.width, 1)
  assert_eq(decoded.height, 1)
  let diff = max_rgb_difference(decoded, strip_alpha(img))
  assert_true(diff <= 6)
}

///|
test "jpeg: the alpha channel is discarded" {
  // A fully transparent red pixel still encodes as red: JPEG has no
  // alpha channel.
  let img = Image::new(
    2,
    2,
    PixelFormat::RGBA8,
    b"\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\x00\x00\x00",
  )
  let bytes = encode_jpeg(img, 95) catch { _ => fail("encode_jpeg raised") }
  let decoded = decode_jpeg(bytes) catch { _ => fail("decode_jpeg raised") }
  assert_eq(decoded.width, 2)
  assert_eq(decoded.height, 2)
  let diff = max_rgb_difference(decoded, strip_alpha(img))
  assert_true(diff <= 6)
}

///|
test "jpeg: a lower quality gives a smaller file" {
  let img = synth_rgb8(32, 32)
  let high = encode_jpeg(img, 95) catch { _ => fail("encode_jpeg raised") }
  let low = encode_jpeg(img, 20) catch { _ => fail("encode_jpeg raised") }
  assert_true(low.length() < high.length())
}

///|
test "jpeg: the quantisation table grows as the quality falls" {
  // At quality 50 the scaling factor is 100, so the first entry of the
  // luminance table keeps its standard value of 16; at quality 25 the
  // factor is 200 and the entry doubles to 32.
  let img = synth_rgb8(8, 8)
  let half = encode_jpeg(img, 50) catch { _ => fail("encode_jpeg raised") }
  let quarter = encode_jpeg(img, 25) catch { _ => fail("encode_jpeg raised") }
  let half_dqt = jpeg_find_marker(half, 0xDB)
  let quarter_dqt = jpeg_find_marker(quarter, 0xDB)
  assert_true(half_dqt > 0)
  assert_true(quarter_dqt > 0)
  // The table is written in zigzagged order; the first entry of the
  // zigzagged luminance table is the natural index 0.
  assert_eq(half[half_dqt + 5], 16)
  assert_eq(quarter[quarter_dqt + 5], 32)
}

///|
test "jpeg: encode rejects a zero-sized image" {
  let img = Image::new(0, 4, PixelFormat::RGB8, b"")
  let res : Result[Bytes, Failure] = Ok(encode_jpeg(img, 85)) catch {
    e => Err(e)
  }
  match res {
    Err(_) => assert_true(true)
    Ok(_) => fail("encode_jpeg accepted a zero-sized image")
  }
}

///|
test "jpeg: the entropy data never contains a bare 0xFF byte" {
  // A 0xFF in the entropy-coded data has to be followed by 0x00, or a
  // decoder would mistake it for a marker.
  let img = synth_rgb8(24, 24)
  let bytes = encode_jpeg(img, 75) catch { _ => fail("encode_jpeg raised") }
  let sos = jpeg_find_marker(bytes, 0xDA)
  assert_true(sos > 0)
  // The scan header ends after three components and three parameter
  // bytes; the entropy data starts right after it.
  let mut i = sos + 2 + 2 + 1 + 6 + 3
  while i < bytes.length() - 2 {
    if bytes[i].to_int() == 0xFF {
      assert_eq(bytes[i + 1].to_int(), 0)
    }
    i = i + 1
  }
}

//-----------------------------------------------------------------------------
// ICO
//-----------------------------------------------------------------------------

///|
test "ico: encode produces an ICONDIR header" {
  let img = synth_rgba8(4, 4)
  let bytes = encode_ico(img) catch { _ => fail("encode_ico raised") }
  // reserved = 0, type = 1 (icon), one image.
  assert_eq(bytes[0], 0)
  assert_eq(bytes[1], 0)
  assert_eq(bytes[2], 1)
  assert_eq(bytes[3], 0)
  assert_eq(bytes[4], 1)
  assert_eq(bytes[5], 0)
}

///|
test "ico: the directory entry records the size and the payload offset" {
  let img = synth_rgba8(6, 5)
  let bytes = encode_ico(img) catch { _ => fail("encode_ico raised") }
  assert_eq(bytes[6], 6) // width
  assert_eq(bytes[7], 5) // height
  assert_eq(bytes[8], 0) // colour count: true colour
  assert_eq(bytes[10], 1) // planes
  assert_eq(bytes[12], 32) // bit count
  // The payload starts right after the 6 byte header and the 16 byte
  // entry.
  assert_eq(bytes[18], 22)
  assert_eq(bytes[19], 0)
  assert_eq(bytes[20], 0)
  assert_eq(bytes[21], 0)
  // bytes_in_res covers the rest of the file.
  let size = bytes[14].to_int() +
    bytes[15].to_int() * 256 +
    bytes[16].to_int() * 65536 +
    bytes[17].to_int() * 16777216
  assert_eq(size, bytes.length() - 22)
}

///|
test "ico: the DIB header covers the XOR bitmap and the AND mask" {
  let img = synth_rgba8(4, 4)
  let bytes = encode_ico(img) catch { _ => fail("encode_ico raised") }
  // The payload starts with a BITMAPINFOHEADER.
  assert_eq(bytes[22], 40)
  assert_eq(bytes[23], 0)
  assert_eq(bytes[24], 0)
  assert_eq(bytes[25], 0)
  // The width is at offset 4 of the header, the height at offset 8.
  assert_eq(bytes[26], 4)
  assert_eq(bytes[27], 0)
  // The height covers the XOR bitmap plus the AND mask, so it is
  // twice the icon height.
  assert_eq(bytes[30], 8)
  assert_eq(bytes[31], 0)
}

///|
test "ico: encode/decode round trip preserves the pixels" {
  let img = synth_rgba8(7, 5)
  let bytes = encode_ico(img) catch { _ => fail("encode_ico raised") }
  let decoded = decode_ico(bytes) catch { _ => fail("decode_ico raised") }
  assert_eq(decoded.width, 7)
  assert_eq(decoded.height, 5)
  assert_eq(format_code(decoded.format), format_code(PixelFormat::RGBA8))
  assert_eq(decoded.data, img.data)
}

///|
test "ico: the alpha channel survives the round trip" {
  // The top-left 2x2 block is fully transparent, the rest is opaque.
  let buf = Array::make(4 * 4 * 4, b'\xFF')
  for i = 0; i < 4; i = i + 1 {
    buf[i * 4 + 3] = b'\x00'
  }
  let img = Image::new(4, 4, PixelFormat::RGBA8, Bytes::from_array(buf))
  let bytes = encode_ico(img) catch { _ => fail("encode_ico raised") }
  let decoded = decode_ico(bytes) catch { _ => fail("decode_ico raised") }
  assert_eq(decoded.width, 4)
  assert_eq(decoded.height, 4)
  for i = 0; i < 4; i = i + 1 {
    assert_eq(decoded.data[i * 4 + 3], 0x00)
  }
  for i = 4; i < 16; i = i + 1 {
    assert_eq(decoded.data[i * 4 + 3], 0xFF)
  }
}

///|
test "ico: a 1x1 image round trips" {
  let img = Image::new(1, 1, PixelFormat::RGBA8, b"\x11\x22\x33\xFF")
  let bytes = encode_ico(img) catch { _ => fail("encode_ico raised") }
  let decoded = decode_ico(bytes) catch { _ => fail("decode_ico raised") }
  assert_eq(decoded.width, 1)
  assert_eq(decoded.height, 1)
  assert_eq(decoded.data, img.data)
}

///|
test "ico: a 256x256 image is written with a zero size byte" {
  // The width and height of the directory entry are single bytes, and
  // 0 means 256.
  let buf = Array::make(256 * 256 * 4, b'\x40')
  let img = Image::new(256, 256, PixelFormat::RGBA8, Bytes::from_array(buf))
  let bytes = encode_ico(img) catch { _ => fail("encode_ico raised") }
  assert_eq(bytes[6], 0)
  assert_eq(bytes[7], 0)
  let decoded = decode_ico(bytes) catch { _ => fail("decode_ico raised") }
  assert_eq(decoded.width, 256)
  assert_eq(decoded.height, 256)
}

///|
test "ico: encode rejects a zero-sized image" {
  let img = Image::new(0, 4, PixelFormat::RGBA8, b"")
  let res : Result[Bytes, Failure] = Ok(encode_ico(img)) catch { e => Err(e) }
  match res {
    Err(_) => assert_true(true)
    Ok(_) => fail("encode_ico accepted a zero-sized image")
  }
}

///|
test "ico: encode rejects an image larger than 256x256" {
  let img = Image::new(300, 4, PixelFormat::RGBA8, b"")
  let res : Result[Bytes, Failure] = Ok(encode_ico(img)) catch { e => Err(e) }
  match res {
    Err(_) => assert_true(true)
    Ok(_) => fail("encode_ico accepted a 300 pixel wide image")
  }
}

//-----------------------------------------------------------------------------
// TIFF
//-----------------------------------------------------------------------------

///|
test "tiff: encode produces a little-endian header" {
  let img = synth_rgba8(4, 4)
  let bytes = encode_tiff(img) catch { _ => fail("encode_tiff raised") }
  assert_eq(bytes[0], b'I')
  assert_eq(bytes[1], b'I')
  assert_eq(bytes[2], 42)
  assert_eq(bytes[3], 0)
  // The IFD starts right after the 8 byte header.
  assert_eq(bytes[4], 8)
  assert_eq(bytes[5], 0)
  assert_eq(bytes[6], 0)
  assert_eq(bytes[7], 0)
}

///|
test "tiff: the IFD records the dimensions" {
  let img = synth_rgba8(6, 3)
  let bytes = encode_tiff(img) catch { _ => fail("encode_tiff raised") }
  // The IFD starts with the entry count, then the entries.
  let count = bytes[8].to_int() + bytes[9].to_int() * 256
  assert_true(count == 11)
  // The first entry is ImageWidth (tag 256), the second ImageLength.
  assert_eq(bytes[10], 0)
  assert_eq(bytes[11], 1)
  assert_eq(bytes[18], 6) // biWidth
  assert_eq(bytes[30], 3) // biHeight
}

///|
test "tiff: encode/decode round trip preserves RGBA8 pixels" {
  let img = synth_rgba8(7, 5)
  let bytes = encode_tiff(img) catch { _ => fail("encode_tiff raised") }
  let decoded = decode_tiff(bytes) catch { _ => fail("decode_tiff raised") }
  assert_eq(decoded.width, 7)
  assert_eq(decoded.height, 5)
  assert_eq(format_code(decoded.format), format_code(PixelFormat::RGBA8))
  assert_eq(decoded.data, img.data)
}

///|
test "tiff: encode/decode round trip preserves Gray8 pixels" {
  let img = synth_gray8(9, 7)
  let bytes = encode_tiff(img) catch { _ => fail("encode_tiff raised") }
  let decoded = decode_tiff(bytes) catch { _ => fail("decode_tiff raised") }
  assert_eq(decoded.width, 9)
  assert_eq(decoded.height, 7)
  assert_eq(format_code(decoded.format), format_code(PixelFormat::Gray8))
  assert_eq(decoded.data, img.data)
}

///|
test "tiff: encode/decode round trip preserves RGB8 pixels" {
  let img = synth_rgb8(5, 4)
  let bytes = encode_tiff(img) catch { _ => fail("encode_tiff raised") }
  let decoded = decode_tiff(bytes) catch { _ => fail("decode_tiff raised") }
  assert_eq(decoded.width, 5)
  assert_eq(decoded.height, 4)
  assert_eq(format_code(decoded.format), format_code(PixelFormat::RGB8))
  assert_eq(decoded.data, img.data)
}

///|
test "tiff: a 1x1 image round trips" {
  let img = Image::new(1, 1, PixelFormat::RGBA8, b"\x11\x22\x33\xFF")
  let bytes = encode_tiff(img) catch { _ => fail("encode_tiff raised") }
  let decoded = decode_tiff(bytes) catch { _ => fail("decode_tiff raised") }
  assert_eq(decoded.width, 1)
  assert_eq(decoded.height, 1)
  assert_eq(decoded.data, img.data)
}

///|
test "tiff: the alpha channel survives the round trip" {
  let buf = Array::make(4 * 4 * 4, b'\xFF')
  for i = 0; i < 4; i = i + 1 {
    buf[i * 4 + 3] = b'\x00'
  }
  let img = Image::new(4, 4, PixelFormat::RGBA8, Bytes::from_array(buf))
  let bytes = encode_tiff(img) catch { _ => fail("encode_tiff raised") }
  let decoded = decode_tiff(bytes) catch { _ => fail("decode_tiff raised") }
  for i = 0; i < 4; i = i + 1 {
    assert_eq(decoded.data[i * 4 + 3], 0x00)
  }
  for i = 4; i < 16; i = i + 1 {
    assert_eq(decoded.data[i * 4 + 3], 0xFF)
  }
}

///|
test "tiff: encode rejects a zero-sized image" {
  let img = Image::new(0, 4, PixelFormat::RGBA8, b"")
  let res : Result[Bytes, Failure] = Ok(encode_tiff(img)) catch { e => Err(e) }
  match res {
    Err(_) => assert_true(true)
    Ok(_) => fail("encode_tiff accepted a zero-sized image")
  }
}

//-----------------------------------------------------------------------------
// The unified encode() entry point
//-----------------------------------------------------------------------------

///|
test "png: encode/decode round trips at every size" {
  // The DEFLATE stream ends with the last symbol followed by padding.
  // When the padding is shorter than the Huffman table's longest code,
  // the decoder has to make do with the bits that are left. These sizes
  // are the ones that used to trip that.
  let sizes = [
    (17, 13),
    (12, 9),
    (13, 9),
    (12, 10),
    (12, 8),
    (9, 12),
    (8, 8),
    (16, 16),
    (33, 17),
    (1, 1),
    (1, 7),
    (7, 1),
  ]
  let mut i = 0
  while i < sizes.length() {
    let (w, h) = sizes[i]
    let img = synth_rgba8(w, h)
    let bytes = encode_png(img) catch { _ => fail("encode_png raised") }
    let decoded = decode_png(bytes) catch {
      e =>
        fail(
          "decode_png raised at " +
          w.to_string() +
          "x" +
          h.to_string() +
          ": " +
          e.to_string(),
        )
    }
    assert_eq(decoded.width, w)
    assert_eq(decoded.height, h)
    assert_eq(decoded.data, img.data)
    i = i + 1
  }
}

///|
test "gif: every size round trips through the encoder and the decoder" {
  // The sizes are the ones that broke the encoder while it was being
  // written: a palette index that collided with the LZW clear code, and
  // a quantiser that stopped early.
  let sizes = [(16, 16), (33, 17), (17, 13), (12, 9), (8, 8), (64, 64)]
  let mut i = 0
  while i < sizes.length() {
    let (w, h) = sizes[i]
    let img = synth_rgba8(w, h)
    let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
    let decoded = decode_gif(bytes) catch {
      e =>
        fail(
          "decode_gif raised at " +
          w.to_string() +
          "x" +
          h.to_string() +
          ": " +
          e.to_string(),
        )
    }
    assert_eq(decoded.width, w)
    assert_eq(decoded.height, h)
    i = i + 1
  }
}

///|
/// The size of the global colour table of a GIF file, in entries.
fn gif_color_table_size(bytes : Bytes) -> Int32 {
  // The packed field of the logical screen descriptor holds the size of
  // the global colour table as the number of doublings of two entries,
  // minus one.
  let packed = bytes[10].to_int()
  1 << ((packed & 0x07) + 1)
}

///|
/// The LZW minimum code size of a GIF file.
fn gif_min_code_size(bytes : Bytes) -> Int32 {
  // The minimum code size is the byte right after the image descriptor,
  // which follows the header, the logical screen descriptor, the colour
  // table and the graphic control extension.
  let mut pos = 13 + gif_color_table_size(bytes) * 3
  while pos < bytes.length() {
    if bytes[pos].to_int() == 0x21 {
      // A graphic control extension: skip its block and its terminator.
      pos = pos + 3 + bytes[pos + 2].to_int() + 1
    } else {
      break
    }
  }
  // The image descriptor is ten bytes, and the minimum code size follows.
  bytes[pos + 10].to_int()
}

///|
test "gif: the transparent index never collides with the LZW clear code" {
  // Sixteen colours plus a transparent pixel used to put the
  // transparent index at 16, which is the clear code of a four bit LZW
  // stream: the decoder then read the clear code as a pixel and fell
  // out of step.
  let buf = Array::make(16 * 16 * 4, b'\xFF')
  for y = 0; y < 16; y = y + 1 {
    for x = 0; x < 16; x = x + 1 {
      let i = (y * 16 + x) * 4
      let k = (x + y) % 16
      buf[i] = (k * 15).to_byte()
      buf[i + 1] = (k * 15).to_byte()
      buf[i + 2] = (k * 15).to_byte()
    }
  }
  // One transparent pixel.
  buf[0] = b'\x00'
  buf[1] = b'\x00'
  buf[2] = b'\x00'
  buf[3] = b'\x00'
  let img = Image::new(16, 16, PixelFormat::RGBA8, Bytes::from_array(buf))
  let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
  // Sixteen colours and one transparent entry need seventeen slots, so
  // the code size has to be five bits, and the clear code 32.
  assert_eq(gif_min_code_size(bytes), 5)
  assert_true(gif_color_table_size(bytes) >= 32)
  let decoded = decode_gif(bytes) catch { _ => fail("decode_gif raised") }
  assert_eq(decoded.width, 16)
  assert_eq(decoded.height, 16)
  // The transparent pixel comes back transparent, and the rest of the
  // image comes back with its exact colours.
  assert_eq(decoded.data[3], b'\x00')
  for i = 1; i < 256; i = i + 1 {
    assert_eq(decoded.data[i * 4], buf[i * 4])
    assert_eq(decoded.data[i * 4 + 1], buf[i * 4 + 1])
    assert_eq(decoded.data[i * 4 + 2], buf[i * 4 + 2])
    assert_eq(decoded.data[i * 4 + 3], b'\xFF')
  }
}

///|
test "gif: a quantised image still uses the whole palette" {
  // The median cut used to stop as soon as one of its boxes could not
  // be split by value, which left the file with a palette of a handful
  // of colours for an image that has hundreds.
  let img = synth_opaque_many(33, 17)
  let bytes = encode_gif(img) catch { _ => fail("encode_gif raised") }
  // 33x17 has more than 256 distinct colours, so the palette has to be
  // full.
  assert_eq(gif_color_table_size(bytes), 256)
  assert_eq(gif_min_code_size(bytes), 8)
  let decoded = decode_gif(bytes) catch { _ => fail("decode_gif raised") }
  assert_eq(decoded.width, 33)
  assert_eq(decoded.height, 17)
  // The quantised colours have to be close to the original ones.
  let orig = img.data
  let mut worst = 0
  let mut i = 0
  while i < 33 * 17 {
    for c = 0; c < 3; c = c + 1 {
      let d = decoded.data[i * 4 + c].to_int() - orig[i * 4 + c].to_int()
      let ad = if d < 0 { -d } else { d }
      if ad > worst {
        worst = ad
      }
    }
    i = i + 1
  }
  assert_true(worst <= 32)
}

///|
test "encode: every encodable format round trips through encode/decode" {
  let img = synth_rgba8(12, 9)
  let formats = [
    ImageFormat::BMP,
    ImageFormat::QOI,
    ImageFormat::TGA,
    ImageFormat::PNG,
    ImageFormat::GIF,
    ImageFormat::JPEG,
    ImageFormat::ICO,
    ImageFormat::TIFF,
  ]
  let mut i = 0
  while i < formats.length() {
    let f = formats[i]
    let bytes = encode(img, f) catch {
      _ => fail("encode failed for " + image_format_name(f))
    }
    assert_true(bytes.length() > 0)
    // The encoded bytes must be recognised as the format they claim.
    match detect_format(bytes) {
      Some(detected) =>
        assert_eq(image_format_name(detected), image_format_name(f))
      None => fail("the encoded " + image_format_name(f) + " was not detected")
    }
    // And they must decode back to an image of the same size.
    let decoded = decode(bytes) catch {
      _ => fail("decode failed for " + image_format_name(f))
    }
    assert_eq(decoded.width, 12)
    assert_eq(decoded.height, 9)
    i = i + 1
  }
}

///|
test "encode: FIM is not encodable" {
  let img = synth_rgba8(4, 4)
  let res : Result[Bytes, DecodeError] = Ok(encode(img, ImageFormat::FIM)) catch {
    e => Err(e)
  }
  match res {
    Err(DecodeError::EncodeNotImplemented(_)) => assert_true(true)
    Ok(_) => fail("encode accepted a FIM image")
    Err(_) => fail("encode raised the wrong error for FIM")
  }
}

///|
test "encode: a zero-sized image is rejected for every format" {
  let img = Image::new(0, 4, PixelFormat::RGBA8, b"")
  let formats = [
    ImageFormat::BMP,
    ImageFormat::QOI,
    ImageFormat::TGA,
    ImageFormat::PNG,
    ImageFormat::GIF,
    ImageFormat::JPEG,
    ImageFormat::ICO,
    ImageFormat::TIFF,
  ]
  let mut i = 0
  while i < formats.length() {
    let f = formats[i]
    let res : Result[Bytes, DecodeError] = Ok(encode(img, f)) catch {
      e => Err(e)
    }
    match res {
      Err(_) => assert_true(true)
      Ok(_) =>
        fail("encode accepted a zero-sized image for " + image_format_name(f))
    }
    i = i + 1
  }
}
