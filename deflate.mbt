// Copyright (c) 2025 lws
// DEFLATE (RFC 1951) compressor and zlib (RFC 1950) wrapper
//
// Used by the PNG encoder. This is a from-scratch implementation: the
// package deliberately has no external runtime dependencies, so the
// compressor cannot be pulled in from a zlib binding.
//
// The compressor emits fixed-Huffman blocks (BTYPE = 01) with LZ77
// back-references. Fixed Huffman avoids having to build and transmit
// dynamic code tables, which costs some ratio on small files but keeps
// the encoder small and the output stream completely standard.
//
// References:
//   RFC 1951 - DEFLATE Compressed Data Format Specification
//   RFC 1950 - ZLIB Compressed Data Format Specification

//-----------------------------------------------------------------------------
// BitWriter - LSB-first bit packer
//-----------------------------------------------------------------------------

///|
/// Accumulates bits into a byte buffer. DEFLATE packs most fields
/// least-significant-bit first; Huffman codes are the exception and are
/// written most-significant-bit first (see `write_huffman`).
priv struct BitWriter {
  buf : Array[Byte]
  mut bit_buf : Int32
  mut bit_count : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { buf: [], bit_buf: 0, bit_count: 0, }
}

///|
/// Append `count` bits of `value`, least-significant bit first.
fn BitWriter::write_bits(
  self : BitWriter,
  value : Int32,
  count : Int32,
) -> Unit {
  self.bit_buf = self.bit_buf | ((value & ((1 << count) - 1)) << self.bit_count)
  self.bit_count = self.bit_count + count
  while self.bit_count >= 8 {
    self.buf.push((self.bit_buf & 0xFF).to_byte())
    self.bit_buf = self.bit_buf >> 8
    self.bit_count = self.bit_count - 8
  }
}

///|
/// Append a Huffman code of `length` bits, most-significant bit first.
/// The code is reversed on the way out, because `write_bits` emits
/// least-significant bit first and Huffman codes are defined MSB-first.
fn BitWriter::write_huffman(
  self : BitWriter,
  code : Int32,
  length : Int32,
) -> Unit {
  let mut reversed = 0
  let mut rest = code
  let mut i = 0
  while i < length {
    reversed = (reversed << 1) | (rest & 1)
    rest = rest >> 1
    i = i + 1
  }
  self.write_bits(reversed, length)
}

///|
/// Flush the partial byte, padding the last byte with zero bits.
fn BitWriter::flush(self : BitWriter) -> Unit {
  if self.bit_count > 0 {
    self.buf.push((self.bit_buf & 0xFF).to_byte())
    self.bit_buf = 0
    self.bit_count = 0
  }
}

///|
/// The bytes written so far.
fn BitWriter::to_bytes(self : BitWriter) -> Bytes {
  Bytes::from_array(self.buf)
}

//-----------------------------------------------------------------------------
// Fixed Huffman code tables
//-----------------------------------------------------------------------------

///|
/// The fixed literal/length code for symbol `sym`, as (code, bit length).
///
/// RFC 1951 section 3.2.6:
///   0..143   -> 8 bits,  codes 00110000..10111111
///   144..255 -> 9 bits,  codes 110010000..111111111
///   256..279 -> 7 bits,  codes 0000000..0010111
///   280..287 -> 8 bits,  codes 11000000..11000111
fn fixed_lit_code(sym : Int32) -> (Int32, Int32) {
  if sym < 144 {
    (0x30 + sym, 8)
  } else if sym < 256 {
    (0x190 + sym - 144, 9)
  } else if sym < 280 {
    (sym - 256, 7)
  } else {
    (0xC0 + sym - 280, 8)
  }
}

///|
/// The DEFLATE length/distance code tables of RFC 1951 section 3.2.5.
///
/// These are table lookups rather than computed formulas: a closed-form
/// shortcut for these tables is easy to get subtly wrong, and a wrong
/// base silently corrupts the whole stream.
priv struct DeflateTables {
  length_base : Array[Int32]
  length_extra : Array[Int32]
  distance_base : Array[Int32]
  distance_extra : Array[Int32]
}

///|
fn DeflateTables::new() -> DeflateTables {
  {
    length_base: [
      3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67,
      83, 99, 115, 131, 163, 195, 227, 258,
    ],
    length_extra: [
      0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5,
      5, 5, 5, 0,
    ],
    distance_base: [
      1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
      1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ],
    distance_extra: [
      0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11,
      11, 12, 12, 13, 13,
    ],
  }
}

///|
/// Base length for each length symbol (257..285).
fn length_base(tables : DeflateTables, sym : Int32) -> Int32 {
  tables.length_base[sym - 257]
}

///|
/// Number of extra bits for each length symbol (257..285).
fn length_extra(tables : DeflateTables, sym : Int32) -> Int32 {
  tables.length_extra[sym - 257]
}

///|
/// Base distance for each distance symbol (0..29).
fn distance_base(tables : DeflateTables, sym : Int32) -> Int32 {
  tables.distance_base[sym]
}

///|
/// Number of extra bits for each distance symbol (0..29).
fn distance_extra(tables : DeflateTables, sym : Int32) -> Int32 {
  tables.distance_extra[sym]
}

///|
/// The length symbol that encodes a match of `len` bytes (3..258).
fn length_symbol(tables : DeflateTables, len : Int32) -> Int32 {
  let mut sym = 285
  let mut s = 257
  while s <= 285 {
    if len < length_base(tables, s) + (1 << length_extra(tables, s)) {
      sym = s
      break
    }
    s = s + 1
  }
  sym
}

///|
/// The distance symbol that encodes a back-reference of `dist` bytes.
fn distance_symbol(tables : DeflateTables, dist : Int32) -> Int32 {
  let mut sym = 29
  let mut s = 0
  while s <= 29 {
    if dist < distance_base(tables, s) + (1 << distance_extra(tables, s)) {
      sym = s
      break
    }
    s = s + 1
  }
  sym
}

//-----------------------------------------------------------------------------
// LZ77 matcher
//-----------------------------------------------------------------------------

///|
const DEFLATE_WINDOW : Int32 = 32768

///|
const DEFLATE_WINDOW_MASK : Int32 = 32767

///|
const DEFLATE_HASH_SIZE : Int32 = 1 << 15

///|
const DEFLATE_HASH_MASK : Int32 = 32767

///|
const DEFLATE_MIN_MATCH : Int32 = 3

///|
const DEFLATE_MAX_MATCH : Int32 = 258

///|
const DEFLATE_MAX_CHAIN : Int32 = 64

///|
/// Hash of the three bytes at `pos`, used to index the match chain.
fn deflate_hash(data : Bytes, pos : Int32) -> Int32 {
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  ((b0 << 10) ^ (b1 << 5) ^ b2) & DEFLATE_HASH_MASK
}

///|
/// Length of the common prefix of `data[pos..]` and `data[back..]`,
/// capped at `max_len` and at the end of the buffer.
fn deflate_match_len(
  data : Bytes,
  pos : Int32,
  back : Int32,
  max_len : Int32,
) -> Int32 {
  let limit = data.length() - pos
  let cap = if max_len < limit { max_len } else { limit }
  let mut len = 0
  while len < cap && data[pos + len] == data[back + len] {
    len = len + 1
  }
  len
}

//-----------------------------------------------------------------------------
// DEFLATE compressor
//-----------------------------------------------------------------------------

///|
/// Compress `data` into a raw DEFLATE stream (no zlib wrapper).
///
/// Uses a single fixed-Huffman block with greedy LZ77 matching.
pub fn deflate_compress(data : Bytes) -> Bytes {
  let writer = BitWriter::new()
  let n = data.length()
  let tables = DeflateTables::new()

  // Block header: BFINAL = 1, BTYPE = 01 (fixed Huffman).
  writer.write_bits(1, 1)
  writer.write_bits(1, 2)

  if n >= DEFLATE_MIN_MATCH {
    // head[h] = most recent position with hash h; prev[p & mask] = the
    // position before it. The window is 32 KiB, so positions are stored
    // modulo the window size.
    let head = Array::make(DEFLATE_HASH_SIZE, -1)
    let prev = Array::make(DEFLATE_WINDOW, -1)

    let mut pos = 0
    while pos < n {
      let mut best_len = 0
      let mut best_dist = 0

      if pos + DEFLATE_MIN_MATCH <= n {
        let h = deflate_hash(data, pos)
        let mut candidate = head[h]
        let mut chain = DEFLATE_MAX_CHAIN
        while candidate >= 0 && chain > 0 {
          let dist = pos - candidate
          if dist > DEFLATE_WINDOW {
            break
          }
          let len = deflate_match_len(data, pos, candidate, DEFLATE_MAX_MATCH)
          if len > best_len {
            best_len = len
            best_dist = dist
            if len >= DEFLATE_MAX_MATCH {
              break
            }
          }
          candidate = prev[candidate & DEFLATE_WINDOW_MASK]
          chain = chain - 1
        }
        // Register this position in the chain.
        prev[pos & DEFLATE_WINDOW_MASK] = head[h]
        head[h] = pos
      }

      if best_len >= DEFLATE_MIN_MATCH {
        // Emit the match.
        let lsym = length_symbol(tables, best_len)
        let lcode = fixed_lit_code(lsym)
        writer.write_huffman(lcode.0, lcode.1)
        let lextra = length_extra(tables, lsym)
        if lextra > 0 {
          writer.write_bits(best_len - length_base(tables, lsym), lextra)
        }
        let dsym = distance_symbol(tables, best_dist)
        writer.write_huffman(dsym, 5)
        let dextra = distance_extra(tables, dsym)
        if dextra > 0 {
          writer.write_bits(best_dist - distance_base(tables, dsym), dextra)
        }
        // Insert the covered positions into the chain so that later
        // matches can still find them.
        let mut k = pos + 1
        while k < pos + best_len && k + DEFLATE_MIN_MATCH <= n {
          let h = deflate_hash(data, k)
          prev[k & DEFLATE_WINDOW_MASK] = head[h]
          head[h] = k
          k = k + 1
        }
        pos = pos + best_len
      } else {
        // Emit a literal.
        let lit = data[pos].to_int()
        let code = fixed_lit_code(lit)
        writer.write_huffman(code.0, code.1)
        pos = pos + 1
      }
    }
  } else {
    let mut i = 0
    while i < n {
      let lit = data[i].to_int()
      let code = fixed_lit_code(lit)
      writer.write_huffman(code.0, code.1)
      i = i + 1
    }
  }

  // End-of-block symbol (256).
  let end = fixed_lit_code(256)
  writer.write_huffman(end.0, end.1)
  writer.flush()
  writer.to_bytes()
}

//-----------------------------------------------------------------------------
// zlib wrapper
//-----------------------------------------------------------------------------

///|
/// Compress `data` into a zlib stream (RFC 1950): a two-byte header,
/// the DEFLATE payload, and the Adler-32 checksum.
pub fn zlib_compress(data : Bytes) -> Bytes {
  let writer = BitWriter::new()
  writer.buf.push(b'\x78') // CM = 8 (deflate), CINFO = 7 (32 KiB window)
  writer.buf.push(b'\x9C') // FCHECK makes 0x789C a multiple of 31; FLEVEL = 2
  let compressed = deflate_compress(data)
  for i = 0; i < compressed.length(); i = i + 1 {
    writer.buf.push(compressed[i])
  }
  let sum = adler32(data)
  writer.buf.push(((sum >> 24) & 0xFF).to_byte())
  writer.buf.push(((sum >> 16) & 0xFF).to_byte())
  writer.buf.push(((sum >> 8) & 0xFF).to_byte())
  writer.buf.push((sum & 0xFF).to_byte())
  writer.to_bytes()
}
