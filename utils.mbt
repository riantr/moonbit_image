// Copyright (c) 2025 lws
// Byte reading utilities for image decoding

//-----------------------------------------------------------------------------
// Byte-level reading helpers
//-----------------------------------------------------------------------------

///|
/// Read a 16-bit unsigned integer in little-endian byte order
fn read_u16_le(data : Bytes, pos : Int32) -> Int32 raise Failure {
  if pos + 2 > data.length() {
    raise Failure::Failure("read_u16_le: position out of bounds")
  }
  let lo = data[pos].to_int()
  let hi = data[pos + 1].to_int()
  lo | (hi << 8)
}

///|
/// Read a 32-bit unsigned integer in little-endian byte order
fn read_u32_le(data : Bytes, pos : Int32) -> Int32 raise Failure {
  if pos < 0 || pos + 4 > data.length() {
    raise Failure::Failure("read_u32_le: position out of bounds")
  }
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  // A u32 that does not fit in an Int32 comes back as a NEGATIVE number,
  // and a negative offset silently defeats every bounds check that
  // compares it against a length. No image this package can hold is 2 GB
  // long, so such a value is a malformed header, not a real one.
  if b3 >= 0x80 {
    raise Failure::Failure("read_u32_le: value exceeds 2^31")
  }
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
/// Read a 32-bit unsigned integer in big-endian byte order
fn read_u32_be(data : Bytes, pos : Int32) -> Int32 raise Failure {
  if pos < 0 || pos + 4 > data.length() {
    raise Failure::Failure("read_u32_be: position out of bounds")
  }
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  // See read_u32_le: a u32 that does not fit in an Int32 would come back
  // negative and would defeat the bounds checks that compare it with a
  // length.
  if b0 >= 0x80 {
    raise Failure::Failure("read_u32_be: value exceeds 2^31")
  }
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

//-----------------------------------------------------------------------------
// CRC-32 checksum (used by PNG)
//-----------------------------------------------------------------------------

///|
/// Pre-computed CRC-32 lookup table (computed once at module init)
let crc32_table : Array[Int32] = make_crc32_table()

///|
/// Logical right shift: forces unsigned semantics by masking out sign-extended bits
fn lsr8(v : Int32) -> Int32 {
  (v >> 8) & 0x00FFFFFF
}

///|
fn lsr1(v : Int32) -> Int32 {
  (v >> 1) & 0x7FFFFFFF
}

///|
fn make_crc32_table() -> Array[Int32] {
  let table = Array::make(256, 0)
  for i = 0; i < 256; i = i + 1 {
    let mut c = i
    for _j = 0; _j < 8; _j = _j + 1 {
      if (c & 1) != 0 {
        c = 0xEDB88320 ^ lsr1(c)
      } else {
        c = lsr1(c)
      }
    }
    table[i] = c
  }
  table
}

///|
/// Compute CRC-32 over multiple Bytes segments efficiently without concatenation
/// Pass previous crc32 result as `initial` to continue (use 0 for first segment)
fn crc32_update(initial : Int32, data : Bytes) -> Int32 {
  let mut c = initial ^ 0xFFFFFFFF
  for i = 0; i < data.length(); i = i + 1 {
    let byte_val = data[i].to_int()
    let idx = (c ^ byte_val) & 0xFF
    c = crc32_table[idx] ^ lsr8(c)
  }
  c ^ 0xFFFFFFFF
}

///|
/// Read the raw 32 bits at `pos` as a bit pattern, without deciding whether
/// they are a number. Some fields are not numbers at all -- a PNG chunk
/// CRC is an arbitrary 32-bit value, and the BMP height is signed by the
/// specification -- and those must not be rejected for being "too large".
fn read_u32_bits_le(data : Bytes, pos : Int32) -> Int32 raise Failure {
  if pos < 0 || pos + 4 > data.length() {
    raise Failure::Failure("read_u32_bits_le: position out of bounds")
  }
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
/// The big-endian counterpart of read_u32_bits_le.
fn read_u32_bits_be(data : Bytes, pos : Int32) -> Int32 raise Failure {
  if pos < 0 || pos + 4 > data.length() {
    raise Failure::Failure("read_u32_bits_be: position out of bounds")
  }
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
/// Multiply two sizes and raise when the product cannot be represented.
/// The sizes come from the file, and an Int32 overflow turns a huge size
/// into a NEGATIVE one, which is what turns a rejected file into a crash.
fn checked_mul(a : Int32, b : Int32) -> Int32 raise Failure {
  if a < 0 || b < 0 {
    raise Failure::Failure("size: negative factor")
  }
  if a != 0 && b > 2147483647 / a {
    raise Failure::Failure("size: overflow")
  }
  a * b
}

///|
/// Largest image the decoders will allocate, in pixels: 2^27 (134 MP).
/// The same cap the reference implementation uses.
const MAX_DECODE_PIXELS : Int32 = 134217728

///|
/// Largest width the decoders will accept, in pixels: 2^24 (16.7 MP).
/// It keeps `width * bytes_per_pixel` inside an Int32, so the row stride
/// and the pitch computed from it cannot overflow.
const MAX_DECODE_WIDTH : Int32 = 16777216

///|
/// Validate the dimensions read from a header BEFORE anything is
/// allocated. Without this a corrupt header can ask for a buffer whose
/// size overflows, and a negative size is a crash, not a rejection.
fn check_decode_size(width : Int32, height : Int32) -> Unit raise Failure {
  if width <= 0 || height <= 0 {
    raise Failure::Failure("invalid dimensions")
  }
  if width > MAX_DECODE_WIDTH {
    raise Failure::Failure("image too wide")
  }
  if width.to_int64() * height.to_int64() > MAX_DECODE_PIXELS.to_int64() {
    raise Failure::Failure("image too large")
  }
}

///|
/// Convenience: compute CRC-32 of chunk_type + chunk_data without allocating
fn crc32_chunk(chunk_type : Bytes, chunk_data : Bytes) -> Int32 {
  let initial = crc32_update(0, chunk_type)
  crc32_update(initial, chunk_data)
}

//-----------------------------------------------------------------------------
// Adler-32 checksum (used by zlib/DEFLATE)
//-----------------------------------------------------------------------------

///|
/// Compute Adler-32 checksum over the given bytes
fn adler32(data : Bytes) -> Int32 {
  let mut s1 = 1
  let mut s2 = 0
  let prime = 65521
  for i = 0; i < data.length(); i = i + 1 {
    let byte_val = data[i].to_int()
    s1 = (s1 + byte_val) % prime
    s2 = (s2 + s1) % prime
  }
  (s2 << 16) | s1
}
