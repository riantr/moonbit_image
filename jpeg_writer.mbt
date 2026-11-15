// Copyright (c) 2025 lws
// JPEG (baseline sequential DCT) encoder
//
// Writes a baseline (SOF0) JFIF file:
//
//   SOI, APP0/JFIF, DQT, SOF0, DHT, SOS, entropy-coded data, EOI
//
// The image is converted to YCbCr and encoded with 4:4:4 sampling, so
// every component has one 8x8 block per MCU and no chroma subsampling
// happens. The quantisation tables are the ones from Annex K of the
// JPEG standard, scaled by the requested quality, and the Huffman
// tables are the standard ones from Annex K.
//
// This is a from-scratch implementation: the package has no external
// runtime dependencies, so neither libjpeg nor a binding to it can be
// used.
//
// Specification: ITU-T T.81 (JPEG), Annex K for the sample tables.

//-----------------------------------------------------------------------------
// Sample tables
//-----------------------------------------------------------------------------

///|
/// The zigzag scan order: entry `i` is the index, in the natural
/// row-major order, of the `i`-th coefficient in the zigzagged order.
fn jpeg_zigzag() -> Array[Int32] {
  [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
    41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22,
    15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55,
    62, 63,
  ]
}

///|
/// The standard luminance quantisation table, in natural order.
fn jpeg_quant_luma() -> Array[Int32] {
  [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24,
    40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103,
    77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72,
    92, 95, 98, 112, 100, 103, 99,
  ]
}

///|
/// The standard chrominance quantisation table, in natural order.
fn jpeg_quant_chroma() -> Array[Int32] {
  [
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99,
    99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99,
  ]
}

///|
/// The number of codes of each length in the standard DC luminance
/// Huffman table.
fn jpeg_dc_luma_bits() -> Array[Int32] {
  [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
}

///|
fn jpeg_dc_luma_values() -> Array[Int32] {
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
}

///|
fn jpeg_dc_chroma_bits() -> Array[Int32] {
  [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
}

///|
fn jpeg_dc_chroma_values() -> Array[Int32] {
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
}

///|
fn jpeg_ac_luma_bits() -> Array[Int32] {
  [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
}

///|
fn jpeg_ac_luma_values() -> Array[Int32] {
  [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13,
    0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42,
    0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A,
    0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35,
    0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A,
    0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67,
    0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84,
    0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3,
    0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7,
    0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1,
    0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
    0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
  ]
}

///|
fn jpeg_ac_chroma_bits() -> Array[Int32] {
  [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
}

///|
fn jpeg_ac_chroma_values() -> Array[Int32] {
  [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51,
    0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1,
    0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24,
    0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26, 0x27, 0x28, 0x29, 0x2A,
    0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66,
    0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82,
    0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA,
    0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9,
    0xDA, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4,
    0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
  ]
}

///|
/// The cosine table of the 8-point DCT, flattened into one array:
/// `cos_flat[u * 8 + x]` is `cos((2x + 1) * u * pi / 16)`.
///
/// The table is flat because the inner loop of the transform reads it once
/// per multiply-accumulate, and a flat array needs one index instead of
/// two.
fn jpeg_cos_table() -> Array[Double] {
  [
    1.0000000000, 1.0000000000, 1.0000000000, 1.0000000000, 1.0000000000, 1.0000000000,
    1.0000000000, 1.0000000000, 0.9807852804, 0.8314696123, 0.5555702330, 0.1950903220,
    -0.1950903220, -0.5555702330, -0.8314696123, -0.9807852804, 0.9238795325, 0.3826834324,
    -0.3826834324, -0.9238795325, -0.9238795325, -0.3826834324, 0.3826834324, 0.9238795325,
    0.8314696123, -0.1950903220, -0.9807852804, -0.5555702330, 0.5555702330, 0.9807852804,
    0.1950903220, -0.8314696123, 0.7071067812, -0.7071067812, -0.7071067812, 0.7071067812,
    0.7071067812, -0.7071067812, -0.7071067812, 0.7071067812, 0.5555702330, -0.9807852804,
    0.1950903220, 0.8314696123, -0.8314696123, -0.1950903220, 0.9807852804, -0.5555702330,
    0.3826834324, -0.9238795325, 0.9238795325, -0.3826834324, -0.3826834324, 0.9238795325,
    -0.9238795325, 0.3826834324, 0.1950903220, -0.5555702330, 0.8314696123, -0.9807852804,
    0.9807852804, -0.8314696123, 0.5555702330, -0.1950903220,
  ]
}

//-----------------------------------------------------------------------------
// Huffman tables
//-----------------------------------------------------------------------------

///|
/// The code and the bit length of one Huffman symbol.
priv struct HuffCode {
  code : Int32
  length : Int32
}

///|
/// A Huffman table: the code of every symbol.
priv struct HuffTable {
  codes : Array[HuffCode]
}

///|
/// Build the canonical Huffman codes of a table from its code counts
/// per length and its symbol values.
fn jpeg_build_huff(bits : Array[Int32], values : Array[Int32]) -> HuffTable {
  let codes = Array::make(256, { code: 0, length: 0, })
  let mut code = 0
  let mut k = 0
  let mut length = 1
  while length <= 16 {
    let mut i = 0
    while i < bits[length - 1] {
      if k < values.length() {
        codes[values[k]] = { code, length, }
        k = k + 1
      }
      code = code + 1
      i = i + 1
    }
    code = code << 1
    length = length + 1
  }
  { codes, }
}

//-----------------------------------------------------------------------------
// Bit writer
//-----------------------------------------------------------------------------

///|
/// Writes JPEG entropy-coded data: bits are packed most significant
/// first, and a 0xFF byte in the output is followed by a 0x00 so that
/// it is not mistaken for a marker.
priv struct JpegBitWriter {
  buf : Array[Byte]
  mut bit_buf : Int32
  mut bit_count : Int32
}

///|
fn JpegBitWriter::new() -> JpegBitWriter {
  { buf: [], bit_buf: 0, bit_count: 0, }
}

///|
/// Append `count` bits of `value`, most significant bit first.
fn JpegBitWriter::write_bits(
  self : JpegBitWriter,
  value : Int32,
  count : Int32,
) -> Unit {
  let mut i = count - 1
  while i >= 0 {
    self.bit_buf = (self.bit_buf << 1) | ((value >> i) & 1)
    self.bit_count = self.bit_count + 1
    if self.bit_count == 8 {
      let b = (self.bit_buf & 0xFF).to_byte()
      self.buf.push(b)
      if b == b'\xFF' {
        // Byte stuffing: a literal 0xFF in entropy-coded data is
        // followed by 0x00.
        self.buf.push(b'\x00')
      }
      self.bit_buf = 0
      self.bit_count = 0
    }
    i = i - 1
  }
}

///|
/// Write a Huffman code.
fn JpegBitWriter::write_code(
  self : JpegBitWriter,
  table : HuffTable,
  symbol : Int32,
) -> Unit {
  let entry = table.codes[symbol]
  self.write_bits(entry.code, entry.length)
}

///|
/// Flush the partial byte, padding with 1 bits as the standard asks.
fn JpegBitWriter::flush(self : JpegBitWriter) -> Unit {
  while self.bit_count != 0 {
    self.write_bits(1, 1)
  }
}

//-----------------------------------------------------------------------------
// Forward DCT and quantisation
//-----------------------------------------------------------------------------

///|
/// The 8-point forward DCT of one block of 64 samples, in natural
/// order. The result is the 64 frequency coefficients in natural
/// (row-major) order.
///
/// `tmp` and `out` are scratch buffers of 64 elements that belong to the
/// caller, so that encoding a block allocates nothing.
///
/// The transform is separable: the first pass transforms the columns and
/// the second one the rows.
fn jpeg_fdct(
  samples : Array[Double],
  cos_table : Array[Double],
  tmp : Array[Double],
  out : Array[Double],
) -> Unit {
  let inv_sqrt2 = 0.7071067812
  // Column pass: tmp[u * 8 + y].
  let mut y = 0
  while y < 8 {
    let row = y * 8
    let mut u = 0
    while u < 8 {
      let base = u * 8
      let mut sum = 0.0
      let mut x = 0
      while x < 8 {
        sum = sum + samples[row + x] * cos_table[base + x]
        x = x + 1
      }
      let scaled = if u == 0 { sum * inv_sqrt2 } else { sum }
      tmp[base + y] = scaled
      u = u + 1
    }
    y = y + 1
  }
  // Row pass: out[v * 8 + u].
  let mut u = 0
  while u < 8 {
    let col = u * 8
    let mut v = 0
    while v < 8 {
      let base = v * 8
      let mut sum = 0.0
      let mut y = 0
      while y < 8 {
        sum = sum + tmp[col + y] * cos_table[base + y]
        y = y + 1
      }
      let scaled = if v == 0 { sum * inv_sqrt2 } else { sum }
      out[v * 8 + u] = scaled * 0.25
      v = v + 1
    }
    u = u + 1
  }
}

///|
/// The number of bits needed to represent `value` in two's complement.
fn jpeg_category(value : Int32) -> Int32 {
  let mut a = if value < 0 { -value } else { value }
  let mut bits = 0
  while a > 0 {
    a = a >> 1
    bits = bits + 1
  }
  bits
}

///|
/// Scale a standard quantisation table by a quality value (1..100).
fn jpeg_scale_quant(base : Array[Int32], quality : Int32) -> Array[Int32] {
  let q = if quality < 1 { 1 } else if quality > 100 { 100 } else { quality }
  let scale = if q < 50 { 5000 / q } else { 200 - q * 2 }
  let out = Array::make(64, 1)
  let mut i = 0
  while i < 64 {
    let mut v = (base[i] * scale + 50) / 100
    if v < 1 {
      v = 1
    }
    if v > 255 {
      v = 255
    }
    out[i] = v
    i = i + 1
  }
  out
}

//-----------------------------------------------------------------------------
// Block encoding
//-----------------------------------------------------------------------------

///|
/// Encode one 8x8 block: the DC coefficient differentially and the AC
/// coefficients with run-length coding.
fn jpeg_encode_block(
  writer : JpegBitWriter,
  samples : Array[Double],
  cos_table : Array[Double],
  quant : Array[Int32],
  zigzag : Array[Int32],
  dc_table : HuffTable,
  ac_table : HuffTable,
  prev_dc : Int32,
  fdct_tmp : Array[Double],
  fdct_out : Array[Double],
  quantised : Array[Int32],
) -> Int32 {
  jpeg_fdct(samples, cos_table, fdct_tmp, fdct_out)
  // Quantise into the zigzagged order.
  let mut i = 0
  while i < 64 {
    let natural = zigzag[i]
    let value = fdct_out[natural] / quant[natural].to_double()
    let rounded = if value < 0.0 {
      -(-value + 0.5).floor().to_int()
    } else {
      (value + 0.5).floor().to_int()
    }
    quantised[i] = rounded
    i = i + 1
  }

  // The DC coefficient is coded as a difference from the previous one.
  let dc = quantised[0]
  let diff = dc - prev_dc
  let category = jpeg_category(diff)
  writer.write_code(dc_table, category)
  if category > 0 {
    // Negative values are stored as the two's complement of the
    // magnitude, which is `value - 1` in the category's bit width.
    let encoded = if diff < 0 { diff - 1 } else { diff }
    writer.write_bits(encoded, category)
  }

  // The AC coefficients are run-length coded.
  let mut run = 0
  let mut k = 1
  while k < 64 {
    let value = quantised[k]
    if value == 0 {
      run = run + 1
    } else {
      while run > 15 {
        // ZRL: sixteen zeroes.
        writer.write_code(ac_table, 0xF0)
        run = run - 16
      }
      let category = jpeg_category(value)
      writer.write_code(ac_table, (run << 4) | category)
      let encoded = if value < 0 { value - 1 } else { value }
      writer.write_bits(encoded, category)
      run = 0
    }
    k = k + 1
  }
  if run > 0 {
    // End of block.
    writer.write_code(ac_table, 0x00)
  }
  dc
}

//-----------------------------------------------------------------------------
// File assembly
//-----------------------------------------------------------------------------

///|
/// Append a marker.
fn jpeg_marker(out : Array[Byte], marker : Int32) -> Unit {
  out.push((0xFF).to_byte())
  out.push(marker.to_byte())
}

///|
/// Append a two-byte big-endian length.
fn jpeg_put_u16(out : Array[Byte], value : Int32) -> Unit {
  out.push(((value >> 8) & 0xFF).to_byte())
  out.push((value & 0xFF).to_byte())
}

///|
/// Encode an image as a baseline JPEG file.
///
/// The quality is a number from 1 (smallest file) to 100 (best
/// quality); 85 is a good default. The image is encoded with 4:4:4
/// sampling, so no chroma subsampling takes place. JPEG has no alpha
/// channel, so the alpha of the source image is discarded.
///
/// # Errors
///
/// Raises `Failure` if the image has zero width or height.
pub fn encode_jpeg(image : Image, quality : Int32) -> Bytes raise Failure {
  if image.width <= 0 || image.height <= 0 {
    raise Failure::Failure(
      "JPEG encode: image dimensions must be positive, got \{image.width}x\{image.height}",
    )
  }

  let rgba = image.to_rgba8()
  let width = rgba.width
  let height = rgba.height
  let pixel_count = width * height

  // The colour transform: RGB to YCbCr, with the samples level shifted
  // so that they are centred on zero.
  let ys = Array::make(pixel_count, 0.0)
  let cbs = Array::make(pixel_count, 0.0)
  let crs = Array::make(pixel_count, 0.0)
  let mut i = 0
  while i < pixel_count {
    let r = rgba.data[i * 4].to_double()
    let g = rgba.data[i * 4 + 1].to_double()
    let b = rgba.data[i * 4 + 2].to_double()
    ys[i] = 0.299 * r + 0.587 * g + 0.114 * b - 128.0
    cbs[i] = -0.168736 * r - 0.331264 * g + 0.5 * b
    crs[i] = 0.5 * r - 0.418688 * g - 0.081312 * b
    i = i + 1
  }

  let zigzag = jpeg_zigzag()
  let quant_luma = jpeg_scale_quant(jpeg_quant_luma(), quality)
  let quant_chroma = jpeg_scale_quant(jpeg_quant_chroma(), quality)
  let cos_table = jpeg_cos_table()

  let dc_luma = jpeg_build_huff(jpeg_dc_luma_bits(), jpeg_dc_luma_values())
  let ac_luma = jpeg_build_huff(jpeg_ac_luma_bits(), jpeg_ac_luma_values())
  let dc_chroma = jpeg_build_huff(
    jpeg_dc_chroma_bits(),
    jpeg_dc_chroma_values(),
  )
  let ac_chroma = jpeg_build_huff(
    jpeg_ac_chroma_bits(),
    jpeg_ac_chroma_values(),
  )

  let out : Array[Byte] = []

  // --- SOI ---
  jpeg_marker(out, 0xD8)

  // --- APP0, the JFIF header ---
  jpeg_marker(out, 0xE0)
  jpeg_put_u16(out, 16)
  out.push(b'J')
  out.push(b'F')
  out.push(b'I')
  out.push(b'F')
  out.push(b'\x00')
  out.push(b'\x01') // version 1.1
  out.push(b'\x01') // minor version
  out.push(b'\x00') // no density units
  jpeg_put_u16(out, 1) // x density
  jpeg_put_u16(out, 1) // y density
  out.push(b'\x00') // no thumbnail width
  out.push(b'\x00') // no thumbnail height

  // --- DQT, both quantisation tables ---
  jpeg_marker(out, 0xDB)
  jpeg_put_u16(out, 2 + 2 * 65)
  out.push(b'\x00') // 8-bit precision, table 0
  let mut i = 0
  while i < 64 {
    out.push(quant_luma[zigzag[i]].to_byte())
    i = i + 1
  }
  out.push(b'\x01') // 8-bit precision, table 1
  i = 0
  while i < 64 {
    out.push(quant_chroma[zigzag[i]].to_byte())
    i = i + 1
  }

  // --- SOF0, the frame header ---
  jpeg_marker(out, 0xC0)
  jpeg_put_u16(out, 8 + 3 * 3)
  out.push(b'\x08') // 8-bit precision
  jpeg_put_u16(out, height)
  jpeg_put_u16(out, width)
  out.push(b'\x03') // three components
  // Y, Cb, Cr, all with 1x1 sampling.
  out.push(b'\x01')
  out.push(b'\x11')
  out.push(b'\x00')
  out.push(b'\x02')
  out.push(b'\x11')
  out.push(b'\x01')
  out.push(b'\x03')
  out.push(b'\x11')
  out.push(b'\x01')

  // --- DHT, the four Huffman tables ---
  let tables = [
    (jpeg_dc_luma_bits(), jpeg_dc_luma_values(), 0x00),
    (jpeg_ac_luma_bits(), jpeg_ac_luma_values(), 0x10),
    (jpeg_dc_chroma_bits(), jpeg_dc_chroma_values(), 0x01),
    (jpeg_ac_chroma_bits(), jpeg_ac_chroma_values(), 0x11),
  ]
  let mut t = 0
  while t < 4 {
    let (bits, values, info) = tables[t]
    jpeg_marker(out, 0xC4)
    jpeg_put_u16(out, 2 + 1 + 16 + values.length())
    out.push(info.to_byte())
    let mut i = 0
    while i < 16 {
      out.push(bits[i].to_byte())
      i = i + 1
    }
    let mut i = 0
    while i < values.length() {
      out.push(values[i].to_byte())
      i = i + 1
    }
    t = t + 1
  }

  // --- SOS, the scan header ---
  jpeg_marker(out, 0xDA)
  jpeg_put_u16(out, 6 + 2 * 3)
  out.push(b'\x03') // three components in the scan
  out.push(b'\x01') // Y
  out.push(b'\x00') // DC table 0, AC table 0
  out.push(b'\x02') // Cb
  out.push(b'\x11') // DC table 1, AC table 1
  out.push(b'\x03') // Cr
  out.push(b'\x11') // DC table 1, AC table 1
  out.push(b'\x00') // spectral selection start
  out.push(b'\x3F') // spectral selection end
  out.push(b'\x00') // successive approximation

  // --- The entropy-coded data ---
  let writer = JpegBitWriter::new()
  let blocks_x = (width + 7) / 8
  let blocks_y = (height + 7) / 8
  let block = Array::make(64, 0.0)
  // The scratch buffers of the block encoder, so that encoding a block
  // allocates nothing.
  let fdct_tmp = Array::make(64, 0.0)
  let fdct_out = Array::make(64, 0.0)
  let quantised = Array::make(64, 0)
  let mut prev_dc_y = 0
  let mut prev_dc_cb = 0
  let mut prev_dc_cr = 0
  let mut by = 0
  while by < blocks_y {
    let mut bx = 0
    while bx < blocks_x {
      // Gather the 8x8 samples of each component, replicating the edge
      // pixels when the image is not a multiple of the block size.
      let mut comp = 0
      while comp < 3 {
        let mut y = 0
        while y < 8 {
          let mut x = 0
          while x < 8 {
            let sx = if bx * 8 + x < width { bx * 8 + x } else { width - 1 }
            let sy = if by * 8 + y < height { by * 8 + y } else { height - 1 }
            let offset = sy * width + sx
            let value = match comp {
              0 => ys[offset]
              1 => cbs[offset]
              _ => crs[offset]
            }
            block[y * 8 + x] = value
            x = x + 1
          }
          y = y + 1
        }
        let quant = if comp == 0 { quant_luma } else { quant_chroma }
        let dc_table = if comp == 0 { dc_luma } else { dc_chroma }
        let ac_table = if comp == 0 { ac_luma } else { ac_chroma }
        let prev = if comp == 0 {
          prev_dc_y
        } else if comp == 1 {
          prev_dc_cb
        } else {
          prev_dc_cr
        }
        let dc = jpeg_encode_block(
          writer, block, cos_table, quant, zigzag, dc_table, ac_table, prev, fdct_tmp,
          fdct_out, quantised,
        )
        if comp == 0 {
          prev_dc_y = dc
        } else if comp == 1 {
          prev_dc_cb = dc
        } else {
          prev_dc_cr = dc
        }
        comp = comp + 1
      }
      bx = bx + 1
    }
    by = by + 1
  }
  writer.flush()

  let mut i = 0
  while i < writer.buf.length() {
    out.push(writer.buf[i])
    i = i + 1
  }

  // --- EOI ---
  jpeg_marker(out, 0xD9)
  Bytes::from_array(out)
}
