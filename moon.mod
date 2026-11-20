name = "riantr/moonbit_image"

version = "0.3.14"

readme = "README.mbt.md"

repository = "https://github.com/riantr/moonbit_image"

license = "MIT"

keywords = [
  "image",
  "codec",
  "bmp",
  "qoi",
  "tga",
  "png",
  "gif",
  "jpeg",
  "ico",
  "tiff",
  "fim",
  "xray",
  "security-scanner",
  "dual-energy",
]

description = "Pure-MoonBit image decoder/encoder covering BMP / QOI / TGA / PNG / GIF / JPEG / ICO / TIFF / FIM with zero external runtime dependencies. Decoders raise a structured `DecodeError` sub-error type so callers can branch on cause (UnsupportedFormat / TruncatedData / InvalidHeader / InvalidValue / EncodeNotImplemented). 0.3.7 re-licensed under MIT only (was `MIT OR Apache-2.0`); see LICENSE-MIT for the full text. 0.3.8 compiles against the current MoonBit core (the `try?` operator was removed upstream) and declares js / wasm-gc support in addition to native. 0.3.9 corrects the release note for 0.3.8; the code is unchanged. 0.3.10 fixes a crash in detect_format() on TGA files carrying a v2 footer and adds decode tests for the JPEG / PNG / GIF / TGA codecs. 0.3.11 adds from-scratch encoders for PNG / GIF / JPEG / TGA / ICO / TIFF (the DEFLATE, LZW and DCT code is written in this package, with no new dependency) and fixes three decoder bugs they exposed: the JPEG inverse DCT transposed every 8x8 block, the PNG inflater dropped the tail of the stream, and the ICO decoder read DIB-only entries at double height. 0.3.12 keeps the release CI's log files out of the published package; the codecs are unchanged. 0.3.13 is the result of a speed and quality comparison against the reference implementation: the TIFF decoder gains LZW / PackBits / Deflate, multiple strips and the horizontal predictor, the TIFF encoder writes compressed strips, the JPEG decoder gets the AAN inverse DCT and an eight-bit-at-a-time Huffman table (about six times faster), the GIF encoder stops writing corrupt files once the LZW table fills up, and the PNG inflater is rewritten. The quality is unchanged and no format is measurably worse than the reference. 0.3.14 hardens every decoder against malformed input: a u32 above 2^31 read into a signed Int32 became a negative offset that passed every bounds check, and the region checks and the allocation sizes themselves overflowed an Int32 on a corrupt header. The decoders now use a checked size helper, a 2^27-pixel cap and Int64 region checks, the JPEG decoder no longer trusts the contents of its segments, and the GIF colour tables and the JPEG marker loop are bounds-checked. PixelFormat and ImageFormat are pub(all), so their variants can be constructed by a consumer, and the package ships a native-only malformed-input regression test."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native+js+wasm-gc",
)
