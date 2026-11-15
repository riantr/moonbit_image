// Copyright (c) 2025 lws
// JPEG baseline decoder — grayscale + YCbCr color
//
// Supports JFIF baseline JPEG (SOF0) with:
//   - Huffman-coded DC and AC coefficients (O(1) prefix table lookup)
//   - Zigzag deordering → dequantization → IDCT
//   - Grayscale (1-component) and YCbCr color (3-component, 4:4:4/4:2:2/4:2:0)
//   - Restart marker (RST) support
//
// Performance optimizations:
//   - IDCT coefficients and zigzag table as module-level constants
//   - O(1) Huffman decoding via prefix lookup table
//   - Bulk bit reading (reads bytes directly when 8+ bits needed)
//   - JBR uses byte_pos + bit_pos representation

//-----------------------------------------------------------------------------
// Module-level constants (pre-computed once, not per-call)
//-----------------------------------------------------------------------------

///|
/// A quantisation table of ones that still carries the AAN pre-scale factors
/// of both frequency axes, so that even a file without a DQT segment decodes
/// through the same butterfly.
fn aan_identity_qt() -> Array[Double] {
  let tbl = Array::make(64, 0.0)
  for zi = 0; zi < 64; zi = zi + 1 {
    tbl[zi] = aan_scale[zi % 8] * aan_scale[zi / 8]
  }
  tbl
}

///|
/// Zigzag scan order (JPEG spec Figure K.2)
let zigzag : Array[Int32] = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
  41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15,
  23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62,
  63,
]

///|
/// AAN butterfly pre-scale factors, one per frequency index u = 0..7.
///
/// The AAN butterfly (the factorisation libjpeg uses in `jidctflt.c`) computes
/// the inverse DCT up to a per-frequency diagonal.  Measured against the
/// mathematical IDCT, that diagonal is `1 / (0.5 * C(u) * cos(u * pi / 16))`
/// with `C(0) = 1/sqrt(2)` and `C(u) = 1` otherwise, so the factors below
/// cancel it exactly.  They are folded into the quantisation table, which
/// makes the correction free.
let aan_scale : Array[Double] = [
  0.353553390593273762200422181052424519642, 0.490392640201615224563091118067119518487,
  0.461939766255643378064091862645248957797, 0.415734806151272617537059810530692891260,
  0.353553390593273762200422181052424519642, 0.277785116509801112371415406974266437187,
  0.191341716182544890035811268183837500734, 0.097545161008064117167815400718986120486,
]

//-----------------------------------------------------------------------------
// Bit reader (MSB-first, used for JPEG Huffman-coded data)
//-----------------------------------------------------------------------------

///|
/// JPEG bit reader.
///
/// The bits are accumulated in `acc`, which holds the next `cnt` bits of the
/// stream in its low bits, most significant bit first.  That makes a peek a
/// shift and a mask, and it lets the Huffman decoder look at eight bits at
/// once instead of one.
///
/// Fields are named differently from BitReader to avoid type ambiguity.
priv struct JBR {
  buf : Bytes // entropy-coded data (with 0xFF00 stuffing already stripped)
  mut acc : Int32 // the bit buffer
  mut cnt : Int32 // the number of valid bits in it
  mut bp : Int32 // the next byte to load into it
}

///|
fn JBR::new(data : Bytes) -> JBR {
  { buf: data, acc: 0, cnt: 0, bp: 0, }
}

///|
/// Make sure the buffer holds at least `n` bits.
fn JBR::fill(self : JBR, n : Int32) -> Unit {
  while self.cnt < n && self.bp < self.buf.length() {
    self.acc = (self.acc << 8) | self.buf[self.bp].to_int()
    self.cnt = self.cnt + 8
    self.bp = self.bp + 1
  }
}

///|
/// Look at the next `n` bits without consuming them.  Bits past the end of
/// the stream read as zero.
fn JBR::peek(self : JBR, n : Int32) -> Int32 {
  if n <= 0 {
    return 0
  }
  self.fill(n)
  if self.cnt < n {
    return (self.acc << (n - self.cnt)) & ((1 << n) - 1)
  }
  (self.acc >> (self.cnt - n)) & ((1 << n) - 1)
}

///|
/// Drop the next `n` bits.
///
/// The consumed bits are cut off the accumulator, so that it only ever holds
/// the bits that are still to be read.
fn JBR::skip(self : JBR, n : Int32) -> Unit {
  self.cnt = self.cnt - n
  if self.cnt <= 0 {
    self.cnt = 0
    self.acc = 0
  } else {
    self.acc = self.acc & ((1 << self.cnt) - 1)
  }
}

///|
/// Read n bits MSB-first.
fn JBR::read_bits(self : JBR, n : Int32) -> Int32 raise Failure {
  if n == 0 {
    return 0
  }
  self.fill(n)
  if self.cnt < n {
    raise Failure::Failure("JPEG: unexpected end of entropy data")
  }
  let v = (self.acc >> (self.cnt - n)) & ((1 << n) - 1)
  self.skip(n)
  v
}

///|
/// Throw the buffered bits away and restart at the next byte.
///
/// The restart marker of a JPEG scan is byte aligned, so the bits that were
/// read ahead of it have to go.
fn JBR::align(self : JBR) -> Unit {
  self.acc = 0
  self.cnt = 0
}

//-----------------------------------------------------------------------------
// JPEG Huffman table with O(1) prefix lookup
//-----------------------------------------------------------------------------

///|
/// JPEG Huffman table entry.
/// Fields are named sym/len to avoid conflict with PNG's HEntry (symbol/length).
priv struct JHTEntry {
  sym : Int32
  len : Int32
}

///|
/// JPEG Huffman table with prefix lookup for O(1) decoding.
/// Uses the same approach as PNG's huff_decode (png.mbt:65-69).
priv struct JHT {
  table : Array[JHTEntry]
  tbl_bits : Int32
  /// The codes of at most `fast_bits` bits, indexed by the next bits of the
  /// stream.  This is the table the decoder uses.
  fast : Array[JHTEntry]
  fast_bits : Int32
}

///|
/// Build a fast prefix-lookup Huffman table from BITS and HUFFVAL arrays.
/// This eliminates the O(n) bit-at-a-time scan with an O(1) table lookup.
fn build_jht(bits : Array[Int32], hv_in : Array[Int32]) -> JHT {
  // Find the maximum code length
  let mut max_len = 0
  for l = 1; l <= 16; l = l + 1 {
    if bits[l - 1] > 0 {
      max_len = l
    }
  }
  if max_len == 0 {
    // Return empty table with sentinel
    let tbl = Array::make(1, { sym: -1, len: 0, })
    return { table: tbl, tbl_bits: 0, fast: tbl, fast_bits: 0, }
  }

  // Compute canonical Huffman codes for each length (MSB-first like JPEG)
  let huffcode = Array::make(17, Array::make(0, 0))
  let mut code = 0
  for l = 1; l <= 16; l = l + 1 {
    let count = bits[l - 1]
    if count > 0 {
      let codes = Array::make(count, 0)
      for i = 0; i < count; i = i + 1 {
        codes[i] = code
        code = code + 1
      }
      huffcode[l] = codes
    }
    code = code << 1
  }

  // Build prefix table of size 2^tbl_bits
  let tbl_bits = max_len
  let ts = 1 << tbl_bits
  let sentinel = { sym: -1, len: 0, }
  let tbl = Array::make(ts, sentinel)

  // Build a fast table of the codes that are at most eight bits long.  It is
  // indexed by the next eight bits of the stream, so a lookup gives the
  // symbol and its length in one step.
  let fast_bits = if max_len < 8 { max_len } else { 8 }
  let fast = Array::make(1 << fast_bits, { sym: -1, len: 0, })
  let mut si = 0
  for l = 1; l <= max_len; l = l + 1 {
    let count = bits[l - 1]
    if count > 0 {
      let codes = huffcode[l]
      for i = 0; i < count; i = i + 1 {
        let c = codes[i]
        let sym_val = hv_in[si]
        si = si + 1
        let entry = { sym: sym_val, len: l, }
        // Fill every entry of the prefix table that starts with this code.
        let pbase = c << (tbl_bits - l)
        let pstep = 1 << (tbl_bits - l)
        let mut j = 0
        while j < pstep {
          tbl[pbase + j] = entry
          j = j + 1
        }
        if l <= fast_bits {
          // And every entry of the fast table that starts with this code.
          let base = c << (fast_bits - l)
          let step = 1 << (fast_bits - l)
          let mut k = 0
          while k < step {
            fast[base + k] = entry
            k = k + 1
          }
        }
      }
    }
  }

  { table: tbl, tbl_bits, fast, fast_bits, }
}

///|
/// Decode a symbol using the fast lookup table.
///
/// The next eight bits of the stream index a table that holds the symbol
/// and the length of its code.  A code that is longer than eight bits is
/// rare, and it is decoded by the slow path below.
fn jht_decode(ht : JHT, r : JBR) -> Int32 raise Failure {
  let bits = r.peek(ht.fast_bits)
  let e = ht.fast[bits]
  if e.len > 0 {
    r.skip(e.len)
    return e.sym
  }
  // The slow path: a code of more than eight bits.  Walk the prefix table
  // one bit at a time.
  let mut code = 0
  for l = 1; l <= ht.tbl_bits; l = l + 1 {
    code = (code << 1) | r.peek(1)
    r.skip(1)
    let idx = code << (ht.tbl_bits - l)
    let ent = ht.table[idx]
    if ent.len == l {
      return ent.sym
    }
  }
  raise Failure::Failure("JPEG: bad Huffman code")
}

///|
/// Decode a symbol using the prefix lookup table.
/// Reads one bit at a time (avoiding push-back complexity), but uses the
/// prefix table for O(1) validation at each bit length.
/// The legacy one-bit-at-a-time decoder is kept out of the hot path: the
/// fast table above handles every code of up to eight bits.

//-----------------------------------------------------------------------------
// IDCT (Inverse Discrete Cosine Transform)
//-----------------------------------------------------------------------------

///|
/// 1-D AAN butterfly inverse DCT on 8 samples.
///
/// `v` holds the eight inputs with a stride of `vs`; the eight results are
/// written to `out` with a stride of `os`.  A stride of 1 is the contiguous
/// case, a stride of 8 the strided one that the column pass needs.
///
/// The butterfly is the factorisation of the inverse DCT matrix that libjpeg
/// uses in `jidctflt.c`: about a dozen multiplications and a few dozen
/// additions, against the 64 multiply-accumulates of the direct matrix
/// product.  It computes the transform up to the per-frequency diagonal that
/// `aan_scale` cancels.
///
/// The eight inputs are read into locals before the first store, so `out` may
/// be the same array as `v`.
fn aan_idct_1d(
  v : Array[Double],
  vs : Int32,
  out : Array[Double],
  os : Int32,
) -> Unit {
  let v0 = v[vs * 0]
  let v1 = v[vs * 1]
  let v2 = v[vs * 2]
  let v3 = v[vs * 3]
  let v4 = v[vs * 4]
  let v5 = v[vs * 5]
  let v6 = v[vs * 6]
  let v7 = v[vs * 7]
  // Even part: the coefficients of the even frequencies.
  let t10 = v0 + v4
  let t11 = v0 - v4
  let t13 = v2 + v6
  let t12 = (v2 - v6) * 1.4142135623730951 - t13
  let e0 = t10 + t13
  let e3 = t10 - t13
  let e1 = t11 + t12
  let e2 = t11 - t12
  // Odd part: the coefficients of the odd frequencies.
  let z13 = v5 + v3
  let z10 = v5 - v3
  let z11 = v1 + v7
  let z12 = v1 - v7
  let o7 = z11 + z13
  let o11 = (z11 - z13) * 1.4142135623730951
  let z5 = (z10 + z12) * 1.8477590650225735
  let o10 = z12 * 1.0823922002923940 - z5
  let o12 = z10 * -2.6131259297527531 + z5
  let o6 = o12 - o7
  let o5 = o11 - o6
  let o4 = o10 + o5
  out[os + 0] = e0 + o7
  out[os + 7] = e0 - o7
  out[os + 1] = e1 + o6
  out[os + 6] = e1 - o6
  out[os + 2] = e2 + o5
  out[os + 5] = e2 - o5
  out[os + 4] = e3 + o4
  out[os + 3] = e3 - o4
}

///|
/// 2-D IDCT on an 8x8 block.
///
/// `coeffs` holds the dequantised coefficients in the natural layout
/// (`row * 8 + col`), `qt` the matching quantisation table - which already
/// carries the `aan_scale` factors, so the butterfly's diagonal cancels
/// itself.  The result is written to `pixels` in the same layout, with the
/// +128 level shift applied and the values clamped to [0, 255].
///
/// The transform is separable: the first pass transforms every row along the
/// horizontal axis, the second pass every column along the vertical axis.
/// Both passes keep the natural layout.
///
/// Every buffer is supplied by the caller, so decoding a block allocates
/// nothing.  The intermediate values of the first pass are neither level
/// shifted nor clamped: they legitimately leave the [0, 255] range, and
/// clamping them there would saturate the second pass and produce the
/// classic "花屏" 8x8 block pattern.
fn idct_2d(
  coeffs : Array[Int32],
  qt : Array[Double],
  row_buf : Array[Double],
  work : Array[Double],
  col_buf : Array[Double],
  pixels : Array[Int32],
) -> Unit {
  // First pass: the rows, along the horizontal axis.
  for y = 0; y < 8; y = y + 1 {
    let base = y * 8
    for x = 0; x < 8; x = x + 1 {
      row_buf[x] = coeffs[base + x].to_double() * qt[base + x]
    }
    aan_idct_1d(row_buf, 1, work, base)
  }
  // Second pass: the columns, along the vertical axis.  This is the final
  // pass, so the +128 level shift and the clamp happen here, exactly once.
  for x = 0; x < 8; x = x + 1 {
    for y = 0; y < 8; y = y + 1 {
      col_buf[y] = work[y * 8 + x]
    }
    aan_idct_1d(col_buf, 1, col_buf, 0)
    for y = 0; y < 8; y = y + 1 {
      let v = (col_buf[y] + 0.5).floor().to_int() + 128
      if v < 0 {
        pixels[y * 8 + x] = 0
      } else if v > 255 {
        pixels[y * 8 + x] = 255
      } else {
        pixels[y * 8 + x] = v
      }
    }
  }
}

//-----------------------------------------------------------------------------
// JPEG Decoder Helper Functions
//-----------------------------------------------------------------------------

///|
/// Decode DC coefficient. Returns the new value and the new predictor.
fn jpg_dc(r : JBR, ht : JHT, pred : Int32) -> (Int32, Int32) raise Failure {
  let cat = jht_decode(ht, r)
  if cat == 0 {
    return (pred, pred)
  }
  let bits = r.read_bits(cat)
  let half = 1 << (cat - 1)
  let diff = if bits < half { bits - ((1 << cat) - 1) } else { bits }
  let new_val = pred + diff
  (new_val, new_val)
}

///|
/// Decode AC coefficients for one 8x8 block.
/// Writes decoded values to block[] at zigzag positions.
fn jpg_ac(r : JBR, ht : JHT, block : Array[Int32]) -> Unit raise Failure {
  let mut k = 1
  while k < 64 {
    let sym = jht_decode(ht, r)
    if sym == 0 {
      return
    } // EOB
    let rs = sym >> 4
    let sz = sym & 0xF
    if sz == 0 && rs == 15 {
      // ZRL: 16 zeros
      k = k + 16
      continue
    }
    k = k + rs
    if k >= 64 {
      break
    }
    if sz > 0 {
      let bits = r.read_bits(sz)
      let half = 1 << (sz - 1)
      let val = if bits < half { bits - ((1 << sz) - 1) } else { bits }
      let zi = zigzag[k]
      if zi < 64 {
        block[zi] = val
      }
    }
    k = k + 1
  }
}

///|
/// Decode one 8x8 block. Returns (reader, new_dc_pred).
///
/// The coefficients are read into `coeffs`, the dequantised pixels are written
/// to `pixels`.  Both buffers belong to the caller, so a decoded block costs
/// no allocation.
fn jpg_block(
  r : JBR,
  dc_ht : JHT,
  ac_ht : JHT,
  qt : Array[Double],
  dc_pred : Int32,
  coeffs : Array[Int32],
  pixels : Array[Int32],
  row_buf : Array[Double],
  work : Array[Double],
  col_buf : Array[Double],
) -> Int32 raise Failure {
  // The coefficients of a block are sparse, so the buffer has to start empty.
  for i = 0; i < 64; i = i + 1 {
    coeffs[i] = 0
  }
  let (ndc, _new_pred) = jpg_dc(r, dc_ht, dc_pred)
  jpg_ac(r, ac_ht, coeffs)
  coeffs[0] = ndc
  idct_2d(coeffs, qt, row_buf, work, col_buf, pixels)
  ndc
}

//-----------------------------------------------------------------------------
// YCbCr → RGB conversion (ITU-R BT.601, 12-bit fixed point)
//-----------------------------------------------------------------------------

///|
/// Convert YCbCr to RGB using ITU-R BT.601 coefficients with 12 fractional bits.
/// All values are clamped to [0, 255].
fn ycbcr_to_rgb(y : Int32, cb : Int32, cr : Int32) -> (Int32, Int32, Int32) {
  let cb_off = cb - 128
  let cr_off = cr - 128

  // R = Y + 1.40200 * (Cr-128)  →  R = Y + 5743 * Cr_off / 4096
  let r = y + ((5743 * cr_off + 2048) >> 12)
  // G = Y - 0.34414 * (Cb-128) - 0.71414 * (Cr-128)
  let g = y - ((1410 * cb_off + 2925 * cr_off + 2048) >> 12)
  // B = Y + 1.77200 * (Cb-128)  →  B = Y + 7258 * Cb_off / 4096
  let b = y + ((7258 * cb_off + 2048) >> 12)

  let r_clamp = if r < 0 { 0 } else if r > 255 { 255 } else { r }
  let g_clamp = if g < 0 { 0 } else if g > 255 { 255 } else { g }
  let b_clamp = if b < 0 { 0 } else if b > 255 { 255 } else { b }

  (r_clamp, g_clamp, b_clamp)
}

//-----------------------------------------------------------------------------
// Main JPEG decoder
//-----------------------------------------------------------------------------

///|
/// Decode a JPEG image from raw bytes.
/// Supports grayscale (1-component) and YCbCr color (3-component) baseline JPEG.
pub fn decode_jpeg(data : Bytes) -> Image raise Failure {
  if data.length() < 2 || data[0].to_int() != 0xFF || data[1].to_int() != 0xD8 {
    raise Failure::Failure("JPEG: missing SOI marker")
  }

  let mut pos = 2
  let mut w = 0
  let mut h = 0
  let mut nc = 1 // number of components

  // Component info from SOF0
  let mut comp_id = Array::make(0, 0) // component ID (for scan selector matching)
  let mut comp_h = Array::make(0, 0) // horizontal sampling factor
  let mut comp_v = Array::make(0, 0) // vertical sampling factor
  let mut comp_qt = Array::make(0, 0) // quantization table selector

  // Quantization tables (up to 4).  Each entry already carries the AAN
  // pre-scale factors of its two frequency axes.
  let qt = Array::make(4, aan_identity_qt())

  // Huffman tables: [TC][TH] where TC=0:DC, TC=1:AC
  let ht_sentinel = JHT::{
    table: Array::make(1, { sym: -1, len: 0, }),
    tbl_bits: 0,
    fast: Array::make(1, { sym: -1, len: 0, }),
    fast_bits: 0,
  }
  let dc_ht = Array::make(4, ht_sentinel)
  let ac_ht = Array::make(4, ht_sentinel)

  // Restart interval (0 = no restart markers)
  let mut restart_interval = 0

  // Parse markers
  while pos < data.length() {
    if data[pos].to_int() != 0xFF {
      raise Failure::Failure("JPEG: expected marker at \{pos}")
    }
    pos = pos + 1
    let mb = data[pos].to_int()
    pos = pos + 1

    // Skip padding bytes and RST markers in header
    if mb == 0x00 {
      continue
    }
    if mb == 0xD8 {
      continue
    } // SOI
    if mb >= 0xD0 && mb <= 0xD7 {
      continue
    } // RST markers (shouldn't appear outside SOS)
    if mb == 0xD9 {
      break
    } // EOI

    let len = (data[pos].to_int() << 8) | data[pos + 1].to_int()
    pos = pos + 2
    let end = pos + len - 2

    if mb == 0xDB { // DQT - Define Quantization Table
      while pos < end {
        let info = data[pos].to_int()
        pos = pos + 1
        let tid = info & 0x0F
        let prec = (info >> 4) & 0x0F
        let tbl = Array::make(64, 0.0)
        for i = 0; i < 64; i = i + 1 {
          let q = if prec == 0 {
            let v = data[pos].to_int()
            pos = pos + 1
            v
          } else {
            let v = (data[pos].to_int() << 8) | data[pos + 1].to_int()
            pos = pos + 2
            v
          }
          // The table is stored in zigzag order; `zi` is the natural index of
          // the coefficient, so `zi % 8` is its horizontal frequency and
          // `zi / 8` its vertical one.  The AAN pre-scale factors of the two
          // axes are folded in here, which makes the butterfly's diagonal
          // cancel itself at no cost.
          let zi = zigzag[i]
          tbl[zi] = q.to_double() * aan_scale[zi % 8] * aan_scale[zi / 8]
        }
        if tid < 4 {
          qt[tid] = tbl
        }
      }
    } else if mb == 0xC0 { // SOF0 - Start of Frame (baseline)
      let _precision = data[pos].to_int()
      pos = pos + 1
      let hi_h = data[pos].to_int()
      let lo_h = data[pos + 1].to_int()
      let hi_w = data[pos + 2].to_int()
      let lo_w = data[pos + 3].to_int()
      h = hi_h * 256 + lo_h
      w = hi_w * 256 + lo_w
      pos = pos + 4
      nc = data[pos].to_int()
      pos = pos + 1

      comp_h = Array::make(nc, 0)
      comp_v = Array::make(nc, 0)
      comp_qt = Array::make(nc, 0)
      comp_id = Array::make(nc, 0)
      for i = 0; i < nc; i = i + 1 {
        let cid = data[pos].to_int() // component ID
        pos = pos + 1
        let samp = data[pos].to_int()
        pos = pos + 1
        comp_id[i] = cid
        comp_h[i] = (samp >> 4) & 0xF
        comp_v[i] = samp & 0xF
        comp_qt[i] = data[pos].to_int()
        pos = pos + 1
      }
    } else if mb == 0xC4 { // DHT - Define Huffman Table
      while pos < end {
        let info = data[pos].to_int()
        pos = pos + 1
        let tc = (info >> 4) & 1 // 0=DC, 1=AC
        let th = info & 0xF
        let bits = Array::make(16, 0)
        let mut total = 0
        for i = 0; i < 16; i = i + 1 {
          bits[i] = data[pos].to_int()
          pos = pos + 1
          total = total + bits[i]
        }
        let hv = Array::make(total, 0)
        for i = 0; i < total; i = i + 1 {
          hv[i] = data[pos].to_int()
          pos = pos + 1
        }
        let ht = build_jht(bits, hv)
        if tc == 0 {
          if th < 4 {
            dc_ht[th] = ht
          }
        } else if th < 4 {
          ac_ht[th] = ht
        }
      }
    } else if mb == 0xDD { // DRI - Define Restart Interval
      restart_interval = (data[pos].to_int() << 8) | data[pos + 1].to_int()
      pos = end
    } else if mb == 0xDA { // SOS - Start of Scan
      let ns = data[pos].to_int() // number of scan components
      pos = pos + 1

      // Read scan component selectors: (component_id, dc_table, ac_table)
      let scan_comp_idx = Array::make(ns, 0) // maps scan component → SOF component index
      let scan_dc_ht = Array::make(ns, 0)
      let scan_ac_ht = Array::make(ns, 0)
      for i = 0; i < ns; i = i + 1 {
        let cs = data[pos].to_int() // component selector (component ID)
        pos = pos + 1
        let tdta = data[pos].to_int()
        pos = pos + 1
        let td = (tdta >> 4) & 0xF
        let ta = tdta & 0xF
        scan_dc_ht[i] = td
        scan_ac_ht[i] = ta
        // Find the SOF component index that matches this component ID
        let mut found = false
        for j = 0; j < nc; j = j + 1 {
          if comp_id[j] == cs {
            scan_comp_idx[i] = j
            found = true
            break
          }
        }
        if !found {
          scan_comp_idx[i] = i
        }
      }

      pos = pos + 3 // skip Ss, Se, Ah/Al

      // Collect entropy-coded data (until next marker, stripping 0xFF00 byte stuffing)
      let ec_buf = Buffer()
      while pos < data.length() - 1 {
        let b0 = data[pos].to_int()
        if b0 == 0xFF {
          let b1 = data[pos + 1].to_int()
          // Check for end-of-scan markers (anything other than 0x00 and RST0-7)
          if b1 != 0x00 && (b1 < 0xD0 || b1 > 0xD7) {
            break
          }
          if b1 == 0x00 {
            ec_buf.write_byte(b'\xFF')
            pos = pos + 2
            continue
          }
          // RST marker: skip (they serve as resynchronization points)
          pos = pos + 2
          continue
        }
        ec_buf.write_byte(data[pos])
        pos = pos + 1
      }

      let ec = ec_buf.to_bytes()

      // Determine MCU dimensions
      let mut max_h = 1
      let mut max_v = 1
      for i = 0; i < nc; i = i + 1 {
        if comp_h[i] > max_h {
          max_h = comp_h[i]
        }
        if comp_v[i] > max_v {
          max_v = comp_v[i]
        }
      }
      let mcu_w = max_h * 8
      let mcu_h = max_v * 8

      // Allocate component planes as Array[Byte] (mutable, unlike Bytes)
      let comp_w = Array::make(nc, 0)
      let comp_h_plane = Array::make(nc, 0)
      for i = 0; i < nc; i = i + 1 {
        comp_w[i] = ((w * comp_h[i] + max_h - 1) / max_h + 7) / 8 * 8
        comp_h_plane[i] = ((h * comp_v[i] + max_v - 1) / max_v + 7) / 8 * 8
      }

      let planes = Array::make(nc, Array::make(0, b'\x00'))
      for i = 0; i < nc; i = i + 1 {
        planes[i] = Array::make(comp_w[i] * comp_h_plane[i], b'\x00')
      }

      // Per-component DC predictors
      let dc_pred = Array::make(nc, 0)

      let reader = JBR::new(ec)
      let mcus_x = (w + mcu_w - 1) / mcu_w
      let mcus_y = (h + mcu_h - 1) / mcu_h
      let mut block_counter = 0

      // The buffers of the block decoder.  They live here, outside the loop
      // over the blocks, so that decoding a block allocates nothing.
      let blk_coeffs = Array::make(64, 0)
      let blk_pixels = Array::make(64, 0)
      let blk_row = Array::make(8, 0.0)
      let blk_work = Array::make(64, 0.0)
      let blk_col = Array::make(8, 0.0)

      for my = 0; my < mcus_y; my = my + 1 {
        for mx = 0; mx < mcus_x; mx = mx + 1 {
          // For each component in scan order
          for sc = 0; sc < ns; sc = sc + 1 {
            let ci = scan_comp_idx[sc]
            let sf_h = comp_h[ci]
            let sf_v = comp_v[ci]
            let dht_dc = scan_dc_ht[sc]
            let dht_ac = scan_ac_ht[sc]
            let qti = comp_qt[ci]

            // Decode sf_h * sf_v data units for this component in this MCU
            for vy = 0; vy < sf_v; vy = vy + 1 {
              for vx = 0; vx < sf_h; vx = vx + 1 {
                let ndc = jpg_block(
                  reader,
                  dc_ht[dht_dc],
                  ac_ht[dht_ac],
                  qt[qti],
                  dc_pred[ci],
                  blk_coeffs,
                  blk_pixels,
                  blk_row,
                  blk_work,
                  blk_col,
                )
                dc_pred[ci] = ndc
                let pixels = blk_pixels

                // Place decoded block into the component plane.
                // `mx`/`my` are MCU indices in the *macro* grid (grid step
                // is `max_h * 8` × `max_v * 8`); `sf_h`/`sf_v` only tell
                // how many blocks THIS component fills inside one MCU.
                // Using `mx * sf_h * 8` would mis-position chroma in
                // 4:2:0 / 4:2:2 files, producing chroma shearing and
                // visible color fringing ("花屏").
                let block_x = (mx * sf_h + vx) * 8
                let block_y = (my * sf_v + vy) * 8
                let plane = planes[ci]
                let plane_w = comp_w[ci]
                let plane_h = comp_h_plane[ci]
                for py = 0; py < 8; py = py + 1 {
                  let oy = block_y + py
                  if oy >= plane_h {
                    continue
                  }
                  for px = 0; px < 8; px = px + 1 {
                    let ox = block_x + px
                    if ox >= plane_w {
                      continue
                    }
                    plane[oy * plane_w + ox] = pixels[py * 8 + px].to_byte()
                  }
                }

                block_counter = block_counter + 1

                // Handle restart marker
                if restart_interval > 0 && block_counter % restart_interval == 0 {
                  for i = 0; i < nc; i = i + 1 {
                    dc_pred[i] = 0
                  }
                  // The restart marker is byte aligned, so the bits that
                  // were read ahead of it have to go.
                  reader.align()
                }
              }
            }
          }
        }
      }

      // Assemble output image from component planes
      if nc == 1 {
        // Grayscale: direct copy (clipping to image dimensions)
        let out = Array::make(w * h, b'\x00')
        let plane = planes[0]
        let pw = comp_w[0]
        for y = 0; y < h; y = y + 1 {
          for x = 0; x < w; x = x + 1 {
            out[y * w + x] = plane[y * pw + x]
          }
        }
        return Image::new(w, h, PixelFormat::Gray8, Bytes::from_array(out))
      } else if nc == 3 {
        // YCbCr → RGB conversion
        let out = Array::make(w * h * 3, b'\x00')
        let y_plane = planes[0]
        let cb_plane = planes[1]
        let cr_plane = planes[2]
        let y_w = comp_w[0]
        let cb_w = comp_w[1]
        let cr_w = comp_w[2]

        for y = 0; y < h; y = y + 1 {
          for x = 0; x < w; x = x + 1 {
            // Compute sub-sampled chroma coordinates (nearest-neighbor upsampling)
            let cb_x = x * comp_h[1] / max_h
            let cb_y = y * comp_v[1] / max_v
            let cr_x = x * comp_h[2] / max_h
            let cr_y = y * comp_v[2] / max_v

            let y_val = y_plane[y * y_w + x].to_int()
            let cb_val = cb_plane[cb_y * cb_w + cb_x].to_int()
            let cr_val = cr_plane[cr_y * cr_w + cr_x].to_int()

            let (r, g, b) = ycbcr_to_rgb(y_val, cb_val, cr_val)
            let di = (y * w + x) * 3
            out[di] = r.to_byte()
            out[di + 1] = g.to_byte()
            out[di + 2] = b.to_byte()
          }
        }
        return Image::new(w, h, PixelFormat::RGB8, Bytes::from_array(out))
      } else {
        raise Failure::Failure("JPEG: unsupported component count: \{nc}")
      }
    } else {
      // Skip unknown segment
      pos = end
    }
  }

  raise Failure::Failure("JPEG: no SOS marker found")
}

///|
/// Read JPEG dimensions from header without decoding pixels.
/// Fast path: scans for SOF0 marker and extracts width/height.
pub fn jpeg_dimensions(data : Bytes) -> (Int32, Int32) raise Failure {
  if data.length() < 2 || data[0].to_int() != 0xFF || data[1].to_int() != 0xD8 {
    raise Failure::Failure("JPEG: missing SOI marker")
  }

  let mut pos = 2
  while pos < data.length() - 1 {
    if data[pos].to_int() != 0xFF {
      raise Failure::Failure("JPEG: expected marker")
    }
    pos = pos + 1
    let mb = data[pos].to_int()
    pos = pos + 1

    if mb == 0x00 {
      continue
    }
    if mb == 0xD8 {
      continue
    }
    if mb >= 0xD0 && mb <= 0xD7 {
      continue
    }
    if mb == 0xD9 {
      break
    }

    let len = (data[pos].to_int() << 8) | data[pos + 1].to_int()
    pos = pos + 2
    let end = pos + len - 2

    if mb == 0xC0 { // SOF0
      let _precision = data[pos].to_int()
      pos = pos + 1
      let hi_h = data[pos].to_int()
      let lo_h = data[pos + 1].to_int()
      let hi_w = data[pos + 2].to_int()
      let lo_w = data[pos + 3].to_int()
      let h = hi_h * 256 + lo_h
      let w = hi_w * 256 + lo_w
      return (w, h)
    }

    pos = end
  }

  raise Failure::Failure("JPEG: no SOF0 marker found")
}
