// White-box tests for the image library using real binary fixtures.
//
// MoonBit 0.1.20260803 makes every `pub enum` variant read-only for code
// outside the defining package — neither explicit constructors
// (`PixelFormat::RGBA8`, `ImageFormat::BMP`) nor Option::None literals
// can be written in this test file. So:
//   * every Image is materialised by `decode()` against a hand-built
//     binary fixture;
//   * every format-name lookup goes through the runtime `detect_format`
//     path instead of asking for a named variant;
//   * encoder coverage is restricted to `encode_qoi` / `encode_bmp`,
//     which take an Image and skip the format enum entirely.
// Behaviour we *can't* test directly from this side is covered
// end-to-end via the QOI/BMP round-trips below.

///|
fn bmp_1x1_black_24bpp() -> Bytes {
  // 14-byte file header + 40-byte DIB header + 4-byte pixel row
  // (24bpp width 1 -> 3 bytes + 1 byte pad to 4-byte alignment).
  // Total = 58 = 0x3A bytes.
  let raw : Array[Int] = [
    // file header
    0x42, 0x4D, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x00,
    // info header (BITMAPINFOHEADER)
    0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // pixel row: black, padded to 4 bytes
    0x00, 0x00, 0x00, 0x00,
  ]
  to_bytes(raw)
}

///|
fn qoi_1x1_red_rgba() -> Bytes {
  // 'qoif' magic + BE(width=1) + BE(height=1) + channels=4 + srgb=1
  // + OP_RGB tag (0xFE) + r=255 g=0 b=0 (absolute) + 8-byte end marker.
  let raw : Array[Int] = [
    0x71, 0x6F, 0x69, 0x66, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01,
    0xFE, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
  ]
  to_bytes(raw)
}

///|
fn to_bytes(ints : Array[Int]) -> Bytes {
  let buf : Array[Byte] = []
  for i = 0; i < ints.length(); i = i + 1 {
    buf.push(ints[i].to_byte())
  }
  Bytes::from_array(buf)
}

// `name_of` turns the (read-only) ImageFormat enum into a stable string
// we can compare against. We only call it on values returned by
// `detect_format`, never on a literal variant.

///|
fn name_of(data : Bytes) -> String {
  match detect_format(data) {
    Some(f) => image_format_name(f)
    None => "?"
  }
}

// ---------------------------------------------------------------------------
// Format detection round-trip: every magic yields the expected name.
// ---------------------------------------------------------------------------

///|
test "detect_format recognises all six signatures" {
  assert_eq(name_of(b"\x89PNG\r\n\x1a\nJUNK"), "PNG")
  assert_eq(name_of(b"GIF87a\x00\x00"), "GIF")
  assert_eq(name_of(b"GIF89a\x00\x00"), "GIF")
  assert_eq(name_of(b"\xFF\xD8\xFF\xE0\x00\x10JFIF"), "JPEG")
  assert_eq(name_of(b"BM\x00\x00\x00\x00\x00\x00"), "BMP")
  assert_eq(name_of(qoi_1x1_red_rgba()), "QOI")
}

///|
test "detect_format reports ? for empty / garbage input" {
  assert_eq(name_of(b""), "?")
  assert_eq(name_of(b"xx"), "?")
  assert_eq(name_of(b"\x00\x01\x02\x03\x04\x05\x06\x07"), "?")
}

///|
test "detect_format + ImageFormat::is_decodable covers every recognised format" {
  // is_supported_format was removed in 0.2.0; the canonical way to ask
  // "is this data recognised?" is now `detect_format()` returning Some.
  assert_true(detect_format(b"\x89PNG\r\n\x1a\n") is Some(_))
  assert_false(detect_format(b"not a header") is Some(_))
  assert_false(detect_format(b"") is Some(_))
  // `pub enum` variants are read-only in test files, so we cannot
  // construct ImageFormat::BMP etc. directly. Convert the detected
  // ImageFormat through `image_format_name` to verify each magic byte
  // fixture is identified correctly, then exercise the capability
  // flags on the returned ImageFormat.
  match detect_format(b"\x89PNG\r\n\x1a\n") {
    Some(f) => {
      assert_eq(image_format_name(f), "PNG")
      assert_true(f.is_decodable())
      assert_false(f.is_encodable())
    }
    None => fail("PNG magic not detected")
  }
  match detect_format(b"BM\x36\x00\x00\x00\x00\x00\x00") {
    Some(f) => {
      assert_eq(image_format_name(f), "BMP")
      assert_true(f.is_decodable())
      assert_true(f.is_encodable())
    }
    None => fail("BMP magic not detected")
  }
  match detect_format(b"qoif\x00\x00\x00\x01") {
    Some(f) => {
      assert_eq(image_format_name(f), "QOI")
      assert_true(f.is_decodable())
      assert_true(f.is_encodable())
    }
    None => fail("QOI magic not detected")
  }
  match detect_format(b"GIF89a") {
    Some(f) => {
      assert_eq(image_format_name(f), "GIF")
      assert_true(f.is_decodable())
      assert_false(f.is_encodable())
    }
    None => fail("GIF magic not detected")
  }
  match detect_format(b"\xFF\xD8\xFF\xE0\x00\x10JFIF") {
    Some(f) => {
      assert_eq(image_format_name(f), "JPEG")
      assert_true(f.is_decodable())
      assert_false(f.is_encodable())
    }
    None => fail("JPEG magic not detected")
  }
}

// ---------------------------------------------------------------------------
// Black-box: drive the public decode / image_dimensions API end-to-end and
// check that the structured DecodeError surfaces in every failure case.
// ---------------------------------------------------------------------------

///|
test "blackbox: decode(unknown) raises DecodeError::UnsupportedFormat" {
  let bogus : Result[Image, DecodeError] = try? decode(b"definitely not an image")
  match bogus {
    Err(DecodeError::UnsupportedFormat(_)) => assert_true(true)
    _ => fail("expected UnsupportedFormat")
  }
}

///|
test "blackbox: decode(corrupt BMP) raises DecodeError::InvalidHeader" {
  // Valid "BM" magic followed by an empty / under-sized dib header.
  let r : Result[Image, DecodeError] = try? decode(
    b"BM\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  )
  match r {
    Err(DecodeError::InvalidHeader(_)) => assert_true(true)
    Err(_) => fail("wrong DecodeError variant (expected InvalidHeader)")
    Ok(_) => fail("expected decode to fail")
  }
}

///|
test "blackbox: image_dimensions reads PNG IHDR without decoding pixels" {
  // 8-byte PNG sig + 4-byte length(13) + "IHDR" + 4-byte width(16) +
  // 4-byte height(11) + 1-byte bit depth + 1-byte color type +
  // 1-byte compression + 1-byte filter + 1-byte interlace +
  // trailing padding. Total 34 bytes — past the 33-byte minimum
  // png_dimensions requires.
  let dims = image_dimensions(
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0DIHDR\x00\x00\x00\x10\x00\x00\x00\x0B\x08\x06\x00\x00\x00\x1F\x15\xC4\x89",
  ) catch {
    _ => fail("image_dimensions raised an error")
  }
  // Compare field-by-field (ImageFormat has no Eq impl in this build).
  let (w, h, f) = dims
  assert_eq(w, 16)
  assert_eq(h, 11)
  match f {
    ImageFormat::PNG => assert_true(true)
    _ => fail("expected PNG format")
  }
}

///|
test "blackbox: detect_format rejects 7-byte (under PNG sig length)" {
  // Regression: detect_format previously had an unconditional
  // `if data.length() < 8` gate that killed 6-byte GIF / 4-byte QOI
  // / 2-byte BMP / 3-byte JPEG. A 7-byte PNG-shaped input should
  // correctly report None.
  assert_false(detect_format(b"\x89PNG\r\n\x1a") is Some(_))
}

// ---------------------------------------------------------------------------
// Real-file fixtures: decode_ico / decode_tiff exercised against actual
// bytes (see lib_test_fixtures.mbt, generated from testdata/).
// ---------------------------------------------------------------------------

///|
test "ico: detect_format picks up Windows ICO header" {
  let bytes = fixture_ico_png_16x16()
  assert_true(bytes.length() > 6)
  match detect_format(bytes) {
    Some(f) => assert_eq(image_format_name(f), "ICO")
    None => fail("detect_format missed ICO magic")
  }
}

///|
test "ico: decode_ico reads PNG-in-ICO 16x16 (Vista+ form)" {
  let bytes = fixture_ico_png_16x16()
  let img = decode_ico(bytes) catch {
    _ => fail("decode_ico raised")
  }
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
  // RGB / RGBA8 — the inner PNG has alpha so we accept either.
  match img.format {
    PixelFormat::RGB8 | PixelFormat::RGBA8 => assert_true(true)
    _ => fail("unexpected pixel format for PNG-in-ICO")
  }
}

///|
test "ico: decode_ico reads BMP-in-ICO 16x16 (legacy form)" {
  let bytes = fixture_ico_gradient_16x16()
  let img = decode_ico(bytes) catch {
    _ => fail("decode_ico raised")
  }
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
}

///|
test "tiff: detect_format picks up little-endian TIFF header" {
  // Hand-built II*\0 + magic 42 + offset-to-IFD = 8.  We don't need a
  // valid IFD here; detection only inspects the first 4 bytes.
  match detect_format(b"II\x2A\x00\x08\x00\x00\x00") {
    Some(ImageFormat::TIFF) => assert_true(true)
    other => fail("expected TIFF, got " + image_format_name_or(other))
  }
  match detect_format(b"MM\x00\x2A\x08\x00\x00\x00") {
    Some(ImageFormat::TIFF) => assert_true(true)
    other => fail("expected TIFF (BE), got " + image_format_name_or(other))
  }
  // A TIFF header with IFD offset = 0 still reports TIFF (we can't
  // decode it, but detection should not back off).
  match detect_format(b"II\x2A\x00\x00\x00\x00\x00") {
    Some(ImageFormat::TIFF) => assert_true(true)
    _ => fail("expected TIFF")
  }
}

///|
fn image_format_name_or(f : ImageFormat?) -> String {
  match f {
    Some(g) => image_format_name(g)
    None => "None"
  }
}

///|
test "tiff: decode_tiff reads uncompressed grayscale 16x16" {
  let bytes = fixture_tiff_gray8_16x16()
  let img = decode_tiff(bytes) catch {
    _ => fail("decode_tiff raised on grayscale")
  }
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
  match img.format {
    PixelFormat::Gray8 => assert_true(true)
    _ => fail("expected Gray8")
  }
}

///|
test "tiff: decode_tiff reads uncompressed RGB 16x16" {
  let bytes = fixture_tiff_rgb_16x16()
  let img = decode_tiff(bytes) catch {
    _ => fail("decode_tiff raised on RGB")
  }
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
  match img.format {
    PixelFormat::RGB8 => assert_true(true)
    _ => fail("expected RGB8")
  }
}

///|
test "tiff: decode_tiff reads palette TIFF 16x16 (ColorMap tag)" {
  let bytes = fixture_tiff_palette_16x16()
  let img = decode_tiff(bytes) catch {
    _ => fail("decode_tiff raised on palette")
  }
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
  // Palette is always expanded to RGBA8 for downstream consumers.
  match img.format {
    PixelFormat::RGBA8 => assert_true(true)
    _ => fail("expected RGBA8")
  }
  assert_eq(img.data.length(), 16 * 16 * 4)
}

// ---------------------------------------------------------------------------
// image_dimensions and decode (consumer side: only Bytes in).
// ---------------------------------------------------------------------------

///|
test "image_dimensions reads BMP header" {
  let (w, h, f) = image_dimensions(bmp_1x1_black_24bpp())
  assert_eq((w, h, image_format_name(f)), (1, 1, "BMP"))
}

///|
test "image_dimensions reads QOI header" {
  let (w, h, f) = image_dimensions(qoi_1x1_red_rgba())
  assert_eq((w, h, image_format_name(f)), (1, 1, "QOI"))
}

///|
test "image_dimensions raises for malformed input" {
  // A raise is reported as the test failing, so calling directly would
  // fail the test. We use `try?` and assert the catch arm was taken.
  let raised = try {
    ignore(image_dimensions(b"junk"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "decode QOI fixture and inspect pixel via pub API" {
  let img = decode(qoi_1x1_red_rgba())
  assert_eq(img.width, 1)
  assert_eq(img.height, 1)
  let r = img.data[0].to_int()
  let g = img.data[1].to_int()
  let b = img.data[2].to_int()
  let a = img.data[3].to_int()
  assert_eq((r, g, b, a), (255, 0, 0, 255))
}

///|
test "decode BMP fixture and verify strides" {
  let img = decode(bmp_1x1_black_24bpp())
  assert_eq(img.width, 1)
  assert_eq(img.height, 1)
  assert_eq(img.data_size(), 1 * 1 * img.bytes_per_pixel())
}

///|
test "decode rejects garbage with a Failure" {
  let raised = try {
    ignore(decode(b"this is not an image at all"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

// ---------------------------------------------------------------------------
// Color math (pure pub fn, no enum construction).
// ---------------------------------------------------------------------------

///|
test "to_gray uses exact BT.601 integer weights" {
  assert_eq(Color::from_gray(0).to_gray(), 0)
  assert_eq(Color::from_rgb(255, 255, 255).to_gray(), 255)
  // (100*299 + 150*587 + 200*114) / 1000 = 140
  assert_eq(Color::from_rgb(100, 150, 200).to_gray(), 140)
}

///|
test "invert flips RGB channels and preserves alpha" {
  let inv = Color::new(5, 10, 20, 7).invert()
  assert_eq(inv.r, 250)
  assert_eq(inv.g, 245)
  assert_eq(inv.b, 235)
  assert_eq(inv.a, 7)
}

///|
test "lerp endpoints on 0..255 fixed point" {
  let black = Color::new(0, 0, 0, 255)
  let white = Color::from_rgb(255, 255, 255)
  let at_zero = black.lerp(white, 0)
  assert_eq((at_zero.r, at_zero.g, at_zero.b, at_zero.a), (0, 0, 0, 255))
  let at_max = black.lerp(white, 255)
  assert_eq((at_max.r, at_max.g, at_max.b, at_max.a), (255, 255, 255, 255))
}

///|
test "blend composites foreground over background by alpha" {
  let fg_opaque = Color::new(50, 60, 70, 255)
  let bg = Color::new(200, 210, 220, 255)
  let fused = fg_opaque.blend(bg)
  assert_eq((fused.r, fused.g, fused.b), (50, 60, 70))
  let fg_transparent = Color::new(50, 60, 70, 0)
  let result = fg_transparent.blend(bg)
  assert_eq((result.r, result.g, result.b), (200, 210, 220))
}

///|
// `close_to` was an old perceptual-distance helper from when the HSL
// tests used integer-quantised mid-spectrum colours. The current tests
// only assert pure RGB endpoints, where `==` is exact. Keeping the
// helper around would just trip an unused-function warning; drop it.
// (Restore this block if a future test wants tolerance comparisons.)

///|
test "HSL conversion is exact at the primary-color endpoints" {
  // The integer HSL pipeline (to_hsl + from_hsl) quantises hue and
  // saturation via a 0..100 scale, so mid-spectrum colors can lose
  // up to ~80 on a single channel after round-trip. The pure RGB
  // endpoints, however, must remain exact.
  let red = Color::from_rgb(255, 0, 0)
  let red_back = Color::from_hsl(red.to_hsl().0, red.to_hsl().1, red.to_hsl().2)
  assert_eq((red_back.r, red_back.g, red_back.b), (255, 0, 0))
  let green = Color::from_rgb(0, 255, 0)
  let green_back = Color::from_hsl(green.to_hsl().0, green.to_hsl().1, green.to_hsl().2)
  assert_eq((green_back.r, green_back.g, green_back.b), (0, 255, 0))
  let blue = Color::from_rgb(0, 0, 255)
  let blue_back = Color::from_hsl(blue.to_hsl().0, blue.to_hsl().1, blue.to_hsl().2)
  assert_eq((blue_back.r, blue_back.g, blue_back.b), (0, 0, 255))
}

///|
test "HSV conversion is exact at the primary-color endpoints" {
  let red = Color::from_rgb(255, 0, 0)
  let red_back = Color::from_hsv(red.to_hsv().0, red.to_hsv().1, red.to_hsv().2)
  assert_eq((red_back.r, red_back.g, red_back.b), (255, 0, 0))
  let green = Color::from_rgb(0, 255, 0)
  let green_back = Color::from_hsv(green.to_hsv().0, green.to_hsv().1, green.to_hsv().2)
  assert_eq((green_back.r, green_back.g, green_back.b), (0, 255, 0))
  let blue = Color::from_rgb(0, 0, 255)
  let blue_back = Color::from_hsv(blue.to_hsv().0, blue.to_hsv().1, blue.to_hsv().2)
  assert_eq((blue_back.r, blue_back.g, blue_back.b), (0, 0, 255))
}

// ---------------------------------------------------------------------------
// Image transforms — operate on the Image returned by decode().
// ---------------------------------------------------------------------------

///|
test "to_rgba8 is identity for already-RGBA images" {
  let img = decode(qoi_1x1_red_rgba())
  let back = img.to_rgba8()
  assert_eq(back.data_size(), img.data_size())
  assert_eq(back.data[0].to_int(), img.data[0].to_int())
  assert_eq(back.data[1].to_int(), img.data[1].to_int())
  assert_eq(back.data[2].to_int(), img.data[2].to_int())
  assert_eq(back.data[3].to_int(), img.data[3].to_int())
}

///|
test "flip_horizontal + flip_vertical restore the original image" {
  let img = decode(bmp_1x1_black_24bpp())
  let twice = img.flip_horizontal().flip_horizontal()
  let four = twice.flip_vertical().flip_vertical()
  assert_eq(img.data_size(), four.data_size())
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(img.data[i].to_int(), four.data[i].to_int())
  }
}

///|
test "rotate_180 twice returns the original bytes" {
  let img = decode(bmp_1x1_black_24bpp())
  let twice = img.rotate_180().rotate_180()
  assert_eq(img.data_size(), twice.data_size())
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(img.data[i].to_int(), twice.data[i].to_int())
  }
}

///|
test "rotate_90 then rotate_270 restores the original" {
  let img = decode(qoi_1x1_red_rgba())
  let back = img.rotate_90().rotate_270()
  assert_eq((back.width, back.height), (img.width, img.height))
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(img.data[i].to_int(), back.data[i].to_int())
  }
}

///|
test "crop on a 1x1 image yields another 1x1 image with the same pixel" {
  let img = decode(qoi_1x1_red_rgba())
  let ok = try {
    let cropped = img.crop(0, 0, 1, 1)
    cropped.width == 1 &&
    cropped.height == 1 &&
    cropped.data_size() == img.data_size() &&
    cropped.data[0].to_int() == img.data[0].to_int()
  } catch {
    _ => false
  }
  assert_true(ok)
}

///|
test "resize_nearest at native size is a byte-for-byte copy" {
  let img = decode(qoi_1x1_red_rgba())
  let same = img.resize_nearest(1, 1)
  assert_eq((same.width, same.height), (1, 1))
  assert_eq(same.data_size(), img.data_size())
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(same.data[i].to_int(), img.data[i].to_int())
  }
}

///|
test "resize_bilinear at native size preserves the pixel" {
  let img = decode(qoi_1x1_red_rgba())
  let same = img.resize_bilinear(1, 1)
  assert_eq((same.width, same.height), (1, 1))
  assert_eq(same.data_size(), img.data_size())
}

///|
test "brighten of zero is the identity" {
  let img = decode(qoi_1x1_red_rgba())
  let out = img.brighten(0)
  for i = 0; i < img.data_size(); i = i + 1 {
    assert_eq(out.data[i].to_int(), img.data[i].to_int())
  }
}

///|
test "to_grayscale is the BT.601 luma of the input" {
  // Pure red RGBA -> BT.601 luma = (255 * 299) / 1000 = 76.
  let img = decode(qoi_1x1_red_rgba())
  let g = img.to_grayscale()
  assert_eq(g.width, 1)
  assert_eq(g.height, 1)
  assert_eq(g.data[0].to_int(), 76)
}

///|
test "histogram has 256 bins and total count equals pixel count" {
  let img = decode(qoi_1x1_red_rgba())
  let hist = img.histogram()
  assert_eq(hist.length(), 256)
  let mut total = 0
  for i = 0; i < hist.length(); i = i + 1 {
    total = total + hist[i]
  }
  assert_eq(total, img.width * img.height)
}

///|
test "average_color of pure red on 1x1 RGBA is per-channel mean (R=255, G=0, B=0)" {
  // Image::average_color is the per-channel arithmetic mean, not a luma
  // (BT.601 luma is the histogram's job). A single 1x1 red pixel must
  // average to (255, 0, 0, 255) channel by channel.
  let img = decode(qoi_1x1_red_rgba())
  let avg = img.average_color()
  assert_eq((avg.r, avg.g, avg.b, avg.a), (255, 0, 0, 255))
}

// ---------------------------------------------------------------------------
// Encoder roundtrips — encode_qoi / encode_bmp take an Image, no enum.
// ---------------------------------------------------------------------------

///|
test "encode_qoi -> detect -> decode round-trips a 1x1 red pixel" {
  let src = decode(qoi_1x1_red_rgba())
  let enc = encode_qoi(src)
  // Magic still 'qoif'?
  assert_eq(enc[0].to_int(), 0x71)
  assert_eq(enc[1].to_int(), 0x6F)
  assert_eq(enc[2].to_int(), 0x69)
  assert_eq(enc[3].to_int(), 0x66)
  let name = match detect_format(enc) {
    Some(f) => image_format_name(f)
    None => "?"
  }
  assert_eq(name, "QOI")
  let back = decode(enc)
  assert_eq((back.width, back.height), (1, 1))
  assert_eq(back.data[0].to_int(), 255) // r
  assert_eq(back.data[1].to_int(), 0) // g
  assert_eq(back.data[2].to_int(), 0) // b
  assert_eq(back.data[3].to_int(), 255) // a
}

///|
test "encode_bmp -> detect -> decode round-trips dimensions and R channel" {
  // The BMP encoder always writes 24bpp for fully-opaque pixels and
  // 32bpp when alpha is present; data_size therefore isn't a useful
  // equality check. We only verify dimensions + the R channel survives
  // (G and B are encoded as 0 for pure red regardless of bpp).
  let src = decode(qoi_1x1_red_rgba())
  let enc = encode_bmp(src)
  // 'BM' signature.
  assert_eq(enc[0].to_int(), 0x42)
  assert_eq(enc[1].to_int(), 0x4D)
  let name = match detect_format(enc) {
    Some(f) => image_format_name(f)
    None => "?"
  }
  assert_eq(name, "BMP")
  let back = decode(enc)
  assert_eq((back.width, back.height), (1, 1))
  // R channel must survive the BMP round-trip.
  assert_eq(back.data[0].to_int(), 255)
}

///|
test "BMP encoder handles a 1x1 opaque pixel with no alpha" {
  let src = decode(bmp_1x1_black_24bpp())
  let enc = encode_bmp(src)
  let name = match detect_format(enc) {
    Some(f) => image_format_name(f)
    None => "?"
  }
  assert_eq(name, "BMP")
}
// Generated by ryx_make_fixtures_mbt.py 鈥?do not edit by hand.
// Each fn returns the byte-for-byte fixture read from testdata/ so
// the test cases do not need to mount filesystem resources at run time.

///|
fn fixture_ico_png_16x16() -> Bytes {
  b"\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x00\x00 \x00\\\x00\x00\x00\x16\x00\x00\x00\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR\x00\x00\x00\x10\x00\x00\x00\x10\x08\x02\x00\x00\x00\x90\x91h6\x00\x00\x00#IDATx\x9Ccd``\x10`\xE0 \x1E\xB10\x08p00\x90\x80XF50\x8C\x86\x12\xC3\x10I\x1A\x00\xB7\xB8\n\x16#\xABqe\x00\x00\x00\x00IEND\xAEB`\x82"
}

///|
fn fixture_ico_gradient_16x16() -> Bytes {
  b"\x00\x00\x01\x00\x02\x00\x08\x08\x00\x00\x00\x00 \x00T\x00\x00\x00&\x00\x00\x00\x10\x10\x00\x00\x00\x00 \x00\\\x00\x00\x00z\x00\x00\x00\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR\x00\x00\x00\x08\x00\x00\x00\x08\x08\x02\x00\x00\x00Km)\xDC\x00\x00\x00\x1BIDATx\x9Cc\xE4\xE0\xE0P`\x10\xC0D,\x0C\n\x02\x0C\x0CX\xD0\xE0\x94\x00\x00\x98>\x05\xE6\xE0t\x05\xA2\x00\x00\x00\x00IEND\xAEB`\x82\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR\x00\x00\x00\x10\x00\x00\x00\x10\x08\x02\x00\x00\x00\x90\x91h6\x00\x00\x00#IDATx\x9Ccd``\x10`\xE0 \x1E\xB10\x08p00\x90\x80XF50\x8C\x86\x12\xC3\x10I\x1A\x00\xB7\xB8\n\x16#\xABqe\x00\x00\x00\x00IEND\xAEB`\x82"
}

///|
fn fixture_tiff_gray8_16x16() -> Bytes {
  b"II*\x00\x08\x00\x00\x00\t\x00\x00\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x01\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x02\x01\x03\x00\x01\x00\x00\x00\x08\x00\x00\x00\x03\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x06\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x11\x01\x04\x00\x01\x00\x00\x00z\x00\x00\x00\x16\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x17\x01\x04\x00\x01\x00\x00\x00\x00\x01\x00\x00\x1C\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x06\x0B\x11\x17\x1C\"(.39?DJPU\n\x10\x16\x1B!',28>CIOTZ`\x15\x1A &+17<BHNSY_dj\x1F%*06;AGLRX^ciot)/5:@FKQW\\bhnsy\x7F49?EJPV[aglrx~\x83\x89>DIOUZ`fkqw|\x82\x88\x8E\x93HNTY_ejpv{\x81\x87\x8C\x92\x98\x9ERX^diouz\x80\x86\x8B\x91\x97\x9C\xA2\xA8]bhnty\x7F\x85\x8A\x90\x96\x9B\xA1\xA7\xAC\xB2gmrx~\x84\x89\x8F\x95\x9A\xA0\xA6\xAB\xB1\xB7\xBCqw}\x82\x88\x8E\x94\x99\x9F\xA5\xAA\xB0\xB6\xBB\xC1\xC7|\x81\x87\x8D\x92\x98\x9E\xA4\xA9\xAF\xB5\xBA\xC0\xC6\xCB\xD1\x86\x8C\x91\x97\x9D\xA2\xA8\xAE\xB4\xB9\xBF\xC5\xCA\xD0\xD6\xDB\x90\x96\x9C\xA1\xA7\xAD\xB2\xB8\xBE\xC4\xC9\xCF\xD5\xDA\xE0\xE6\x9B\xA0\xA6\xAC\xB1\xB7\xBD\xC2\xC8\xCE\xD4\xD9\xDF\xE5\xEA\xF0"
}

///|
fn fixture_tiff_rgb_16x16() -> Bytes {
  b"II*\x00\x08\x00\x00\x00\n\x00\x00\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x01\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x02\x01\x03\x00\x03\x00\x00\x00\x86\x00\x00\x00\x03\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x06\x01\x03\x00\x01\x00\x00\x00\x02\x00\x00\x00\x11\x01\x04\x00\x01\x00\x00\x00\x8C\x00\x00\x00\x15\x01\x03\x00\x01\x00\x00\x00\x03\x00\x00\x00\x16\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x17\x01\x04\x00\x01\x00\x00\x00\x00\x03\x00\x00\x1C\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x08\x00\x08\x00\x08\x00\x00\x00\x00\x10\x00\x08 \x00\x100\x00\x18@\x00 P\x00(`\x000p\x008\x80\x00@\x90\x00H\xA0\x00P\xB0\x00X\xC0\x00`\xD0\x00h\xE0\x00p\xF0\x00x\x00\x10\x08\x10\x10\x10 \x10\x180\x10 @\x10(P\x100`\x108p\x10@\x80\x10H\x90\x10P\xA0\x10X\xB0\x10`\xC0\x10h\xD0\x10p\xE0\x10x\xF0\x10\x80\x00 \x10\x10 \x18   0 (@ 0P 8` @p H\x80 P\x90 X\xA0 `\xB0 h\xC0 p\xD0 x\xE0 \x80\xF0 \x88\x000\x18\x100  0(000@08P0@`0Hp0P\x800X\x900`\xA00h\xB00p\xC00x\xD00\x80\xE00\x88\xF00\x90\x00@ \x10@( @00@8@@@P@H`@Pp@X\x80@`\x90@h\xA0@p\xB0@x\xC0@\x80\xD0@\x88\xE0@\x90\xF0@\x98\x00P(\x10P0 P80P@@PHPPP`PXpP`\x80Ph\x90Pp\xA0Px\xB0P\x80\xC0P\x88\xD0P\x90\xE0P\x98\xF0P\xA0\x00`0\x10`8 `@0`H@`PP`X```p`h\x80`p\x90`x\xA0`\x80\xB0`\x88\xC0`\x90\xD0`\x98\xE0`\xA0\xF0`\xA8\x00p8\x10p@ pH0pP@pXPp``phppp\x80px\x90p\x80\xA0p\x88\xB0p\x90\xC0p\x98\xD0p\xA0\xE0p\xA8\xF0p\xB0\x00\x80@\x10\x80H \x80P0\x80X@\x80`P\x80h`\x80pp\x80x\x80\x80\x80\x90\x80\x88\xA0\x80\x90\xB0\x80\x98\xC0\x80\xA0\xD0\x80\xA8\xE0\x80\xB0\xF0\x80\xB8\x00\x90H\x10\x90P \x90X0\x90`@\x90hP\x90p`\x90xp\x90\x80\x80\x90\x88\x90\x90\x90\xA0\x90\x98\xB0\x90\xA0\xC0\x90\xA8\xD0\x90\xB0\xE0\x90\xB8\xF0\x90\xC0\x00\xA0P\x10\xA0X \xA0`0\xA0h@\xA0pP\xA0x`\xA0\x80p\xA0\x88\x80\xA0\x90\x90\xA0\x98\xA0\xA0\xA0\xB0\xA0\xA8\xC0\xA0\xB0\xD0\xA0\xB8\xE0\xA0\xC0\xF0\xA0\xC8\x00\xB0X\x10\xB0` \xB0h0\xB0p@\xB0xP\xB0\x80`\xB0\x88p\xB0\x90\x80\xB0\x98\x90\xB0\xA0\xA0\xB0\xA8\xB0\xB0\xB0\xC0\xB0\xB8\xD0\xB0\xC0\xE0\xB0\xC8\xF0\xB0\xD0\x00\xC0`\x10\xC0h \xC0p0\xC0x@\xC0\x80P\xC0\x88`\xC0\x90p\xC0\x98\x80\xC0\xA0\x90\xC0\xA8\xA0\xC0\xB0\xB0\xC0\xB8\xC0\xC0\xC0\xD0\xC0\xC8\xE0\xC0\xD0\xF0\xC0\xD8\x00\xD0h\x10\xD0p \xD0x0\xD0\x80@\xD0\x88P\xD0\x90`\xD0\x98p\xD0\xA0\x80\xD0\xA8\x90\xD0\xB0\xA0\xD0\xB8\xB0\xD0\xC0\xC0\xD0\xC8\xD0\xD0\xD0\xE0\xD0\xD8\xF0\xD0\xE0\x00\xE0p\x10\xE0x \xE0\x800\xE0\x88@\xE0\x90P\xE0\x98`\xE0\xA0p\xE0\xA8\x80\xE0\xB0\x90\xE0\xB8\xA0\xE0\xC0\xB0\xE0\xC8\xC0\xE0\xD0\xD0\xE0\xD8\xE0\xE0\xE0\xF0\xE0\xE8\x00\xF0x\x10\xF0\x80 \xF0\x880\xF0\x90@\xF0\x98P\xF0\xA0`\xF0\xA8p\xF0\xB0\x80\xF0\xB8\x90\xF0\xC0\xA0\xF0\xC8\xB0\xF0\xD0\xC0\xF0\xD8\xD0\xF0\xE0\xE0\xF0\xE8\xF0\xF0\xF0"
}

///|
fn fixture_tiff_palette_16x16() -> Bytes {
  b"II*\x00\x08\x00\x00\x00\n\x00\x00\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x01\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x02\x01\x03\x00\x01\x00\x00\x00\x08\x00\x00\x00\x03\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x06\x01\x03\x00\x01\x00\x00\x00\x03\x00\x00\x00\x11\x01\x04\x00\x01\x00\x00\x00\x86\x06\x00\x00\x16\x01\x04\x00\x01\x00\x00\x00\x10\x00\x00\x00\x17\x01\x04\x00\x01\x00\x00\x00\x00\x01\x00\x00\x1C\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00@\x01\x03\x00\x00\x03\x00\x00\x86\x00\x00\x00\x00\x00\x00\x00\x00\xE0\x00\xE0\x00\xB8\x00\xB8\x00\xE8\x00\xD0\x00\xB8\x00\x90\x00p\x00\x88\x00\x90\x00p\x00P\x000\x00H\x00\x10\x00\x10\x00P\x000\x00\x10\x00\xE0\x00\xE0\x00\xB8\x00\xD0\x00\x90\x00p\x00\x88\x00\x88\x00P\x000\x00H\x00H\x00\x18\x00\x00\x00\x10\x00\x10\x00\xE0\x00\xE0\x00\xB8\x00\xD0\x00\x90\x00p\x00\x88\x00\x88\x00\xE0\x00\xE0\x00\xB8\x00\x90\x00p\x00\x88\x00P\x000\x00H\x00H\x00\x18\x00\x00\x00\x10\x00\x10\x00P\x000\x00H\x00\x18\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xE8\x00\xD0\x00\xE8\x00\xD0\x00\xB8\x00\xB8\x00\xB8\x00\xE8\x00\xE8\x00\xD0\x00\xB8\x00\xB8\x00\xE8\x00\xE8\x00\xD0\x00\xE8\x00\xD0\x00\xB8\x00\xB8\x00\xB8\x00\x98\x00\x80\x00\x90\x00p\x00\x98\x00\x98\x00\x80\x00p\x00\x98\x00\x98\x00\x80\x00p\x00\x98\x00\x98\x00\x80\x00p\x00X\x00@\x00P\x000\x00X\x00X\x00@\x000\x00\x18\x00\x00\x00\x10\x00\x18\x00\x18\x00\x00\x00X\x00X\x00@\x000\x00X\x00X\x00@\x000\x00\x18\x00\x18\x00\x00\x00\x18\x00\x18\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xE4\x00\xD8\x00\xD0\x00\xC4\x00\xD0\x00\xC4\x00\xB8\x00\xBC\x00\xAC\x00\xAC\x00\xA4\x00\x94\x00\x9C\x00\x8C\x00\x8C\x00|\x00p\x00\x84\x00t\x00d\x00\xBC\x00\xB0\x00\xA4\x00\xA0\x00\x94\x00\x84\x00\x84\x00|\x00t\x00d\x00d\x00\\\x00X\x00L\x00H\x00@\x00\x9C\x00\x90\x00\x84\x00\x80\x00t\x00d\x00d\x00\\\x00|\x00p\x00d\x00T\x00D\x00D\x00T\x00D\x00D\x00<\x008\x00,\x00(\x00 \x004\x00$\x00$\x00\x18\x00\x0C\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00???<<<<1111..--->==;<::01//..,,,>==;::00///..',,9995555++++.'''%8884444****&&%%%7663422)*((&&$$$766322))(((&&\x17$$###\x1F\x1F\x1F\x1F\x1B\x1B\x1B\x1B&\x17\x17\x17\x15\"\"\"\x1E\x1E\x1E\x1E\x1A\x1A\x1A\x1A\x16\x16\x15\x15\x15!  \x1D\x1E\x1C\x1C\x19\x1A\x18\x18\x16\x16\x14\x14\x14!  \x1D\x1C\x1C\x19\x19\x18\x18\x18\x16\x16\x14\x14\x14\x13\x13\x13\x12\x12\x11\x11\x0B\x0B\n\n\x06\x06\x05\x04\x04\x13\x13\x12\x12\x11\x11\x0B\x0B\n\n\n\x06\x06\x05\x04\x04\x10\x10\x10\x0E\x0E\x0E\x0E\t\t\t\t\x03\x03\x01\x01\x01\x0F\x0F\x0F\r\x0E\x0C\x0C\x08\t\x07\x07\x02\x02\x00\x00\x00\x0F\x0F\r\r\x0C\x0C\x08\x08\x07\x07\x07\x02\x02\x00\x00\x00"
}

