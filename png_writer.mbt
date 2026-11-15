// Copyright (c) 2025 lws
// PNG (Portable Network Graphics) encoder
//
// Writes 8-bit-per-channel PNG files in the four colour types that map
// one-to-one onto this package's `PixelFormat`:
//
//   Gray8   -> colour type 0 (greyscale)
//   RGB8    -> colour type 2 (truecolour)
//   GrayA8  -> colour type 4 (greyscale + alpha)
//   RGBA8   -> colour type 6 (truecolour + alpha)
//
// The pixel data is filtered with the standard five PNG filters (None,
// Sub, Up, Average, Paeth), choosing per row the filter with the
// smallest sum of absolute differences - the heuristic recommended by
// the PNG specification. The filtered stream is then compressed with the
// package's own DEFLATE encoder (see `deflate.mbt`).
//
// Specification: PNG Portable Network Graphics, W3C/ISO 15948

//-----------------------------------------------------------------------------
// Colour type mapping
//-----------------------------------------------------------------------------

///|
/// The PNG colour type that matches a `PixelFormat`, or -1 when the
/// format has no PNG equivalent. All four supported formats are 8 bits
/// per channel, so no bit-depth juggling is needed.
fn png_color_type(format : PixelFormat) -> Int32 {
  match format {
    PixelFormat::Gray8 => 0
    PixelFormat::RGB8 => 2
    PixelFormat::GrayA8 => 4
    PixelFormat::RGBA8 => 6
  }
}

//-----------------------------------------------------------------------------
// Scanline filtering
//-----------------------------------------------------------------------------

///|
/// Sum of the filtered bytes interpreted as signed values. The PNG
/// specification recommends picking the filter with the smallest such
/// sum, because it correlates well with the entropy of the row.
fn filter_cost(row : Array[Byte], count : Int32) -> Int32 {
  let mut sum = 0
  let mut i = 0
  while i < count {
    let b = row[i].to_int()
    // Treat the byte as signed: values above 127 count as negative.
    let signed = if b > 127 { b - 256 } else { b }
    sum = sum + (if signed < 0 { -signed } else { signed })
    i = i + 1
  }
  sum
}

///|
/// The Paeth predictor of RFC 2083 section 6.6.
fn paeth_predictor(a : Int32, b : Int32, c : Int32) -> Int32 {
  let p = a + b - c
  let pa = if p > a { p - a } else { a - p }
  let pb = if p > b { p - b } else { b - p }
  let pc = if p > c { p - c } else { c - p }
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// Filter one scanline with the given filter type and write it to
/// `out`. `raw` is the unfiltered row, `prior` the row above it (or an
/// all-zero row for the first line) and `bpp` the bytes per pixel.
fn png_filter_row(
  out : Array[Byte],
  out_pos : Int32,
  filter : Int32,
  raw : Bytes,
  row_start : Int32,
  row_len : Int32,
  prior : Bytes,
  prior_start : Int32,
  bpp : Int32,
) -> Unit {
  let mut i = 0
  while i < row_len {
    let x = raw[row_start + i].to_int()
    let left = if i >= bpp { raw[row_start + i - bpp].to_int() } else { 0 }
    let up = prior[prior_start + i].to_int()
    let up_left = if i >= bpp {
      prior[prior_start + i - bpp].to_int()
    } else {
      0
    }
    let v = match filter {
      0 => x
      1 => x - left
      2 => x - up
      3 => x - (left + up) / 2
      _ => x - paeth_predictor(left, up, up_left)
    }
    out[out_pos + i] = (v & 0xFF).to_byte()
    i = i + 1
  }
}

///|
/// Build the filtered raw stream that a PNG file stores in its IDAT
/// chunk: one filter-type byte followed by the filtered row, for every
/// row of the image.
fn png_filter_stream(image : Image) -> Bytes {
  let bpp = image.bytes_per_pixel()
  let stride = image.stride()
  let out = Array::make(stride * image.height + image.height, b'\x00')
  let zero_row = Bytes::from_array(Array::make(stride, b'\x00'))

  // Scratch buffers for the five candidate filters of the current row.
  let candidate = Array::make(stride, b'\x00')

  let mut row = 0
  while row < image.height {
    let row_start = row * stride
    let prior_start = if row == 0 { 0 } else { (row - 1) * stride }
    let prior = if row == 0 { zero_row } else { image.data }
    let out_pos = row * (stride + 1)

    let mut best_filter = 0
    let mut best_cost = -1
    let mut filter = 0
    while filter < 5 {
      png_filter_row(
        candidate,
        0,
        filter,
        image.data,
        row_start,
        stride,
        prior,
        prior_start,
        bpp,
      )
      let cost = filter_cost(candidate, stride)
      if best_cost < 0 || cost < best_cost {
        best_cost = cost
        best_filter = filter
      }
      filter = filter + 1
    }
    out[out_pos] = best_filter.to_byte()
    png_filter_row(
      out,
      out_pos + 1,
      best_filter,
      image.data,
      row_start,
      stride,
      prior,
      prior_start,
      bpp,
    )
    row = row + 1
  }
  Bytes::from_array(out)
}

//-----------------------------------------------------------------------------
// Chunk assembly
//-----------------------------------------------------------------------------

///|
/// Append a 32-bit unsigned integer in big-endian byte order.
fn png_push_u32_be(out : Array[Byte], value : Int32) -> Unit {
  out.push(((value >> 24) & 0xFF).to_byte())
  out.push(((value >> 16) & 0xFF).to_byte())
  out.push(((value >> 8) & 0xFF).to_byte())
  out.push((value & 0xFF).to_byte())
}

///|
/// Append a PNG chunk: a big-endian length, the four type bytes, the
/// payload and the CRC-32 of type + payload.
fn png_write_chunk(
  out : Array[Byte],
  chunk_type : String,
  data : Bytes,
) -> Unit {
  let payload_len = data.length()
  png_push_u32_be(out, payload_len)
  let type_bytes = Bytes::from_array([
    chunk_type[0].to_byte(),
    chunk_type[1].to_byte(),
    chunk_type[2].to_byte(),
    chunk_type[3].to_byte(),
  ])
  for i = 0; i < 4; i = i + 1 {
    out.push(type_bytes[i])
  }
  for i = 0; i < payload_len; i = i + 1 {
    out.push(data[i])
  }
  // The CRC covers the type bytes and the payload, but not the length.
  png_push_u32_be(out, crc32_chunk(type_bytes, data))
}

///|
/// The 8-byte PNG signature.
fn png_signature() -> Bytes {
  Bytes::from_array([
    b'\x89', b'P', b'N', b'G', b'\x0D', b'\x0A', b'\x1A', b'\x0A',
  ])
}

//-----------------------------------------------------------------------------
// PNG encoder
//-----------------------------------------------------------------------------

///|
/// Encode an image as a PNG file.
///
/// The colour type follows the image's own `PixelFormat`, so no pixel
/// conversion happens: a `Gray8` image becomes an 8-bit greyscale PNG, a
/// `RGBA8` image becomes an 8-bit truecolour-with-alpha PNG.
///
/// Rows are filtered with the PNG filter heuristic and the result is
/// compressed with this package's own DEFLATE encoder, so the output
/// carries no external dependency.
///
/// # Errors
///
/// Raises `Failure` if the image has zero width or height.
pub fn encode_png(image : Image) -> Bytes raise Failure {
  if image.width <= 0 || image.height <= 0 {
    raise Failure::Failure(
      "PNG encode: image dimensions must be positive, got \{image.width}x\{image.height}",
    )
  }

  let color_type = png_color_type(image.format)
  let bit_depth = 8

  let out = []
  let sig = png_signature()
  for i = 0; i < 8; i = i + 1 {
    out.push(sig[i])
  }

  // IHDR: width, height, bit depth, colour type, compression, filter,
  // interlace - all big-endian.
  let ihdr = Array::make(13, b'\x00')
  write_u32_be_buf(ihdr, 0, image.width)
  write_u32_be_buf(ihdr, 4, image.height)
  ihdr[8] = bit_depth.to_byte()
  ihdr[9] = color_type.to_byte()
  ihdr[10] = b'\x00' // compression method: deflate
  ihdr[11] = b'\x00' // filter method: adaptive
  ihdr[12] = b'\x00' // interlace method: none
  png_write_chunk(out, "IHDR", Bytes::from_array(ihdr))

  // IDAT: the filtered scanlines, compressed as a zlib stream.
  let raw = png_filter_stream(image)
  let compressed = zlib_compress(raw)
  png_write_chunk(out, "IDAT", compressed)

  // IEND: an empty chunk that closes the file.
  png_write_chunk(out, "IEND", Bytes::from_array(Array::make(0, b'\x00')))

  Bytes::from_array(out)
}
