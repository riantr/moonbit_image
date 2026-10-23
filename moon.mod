name = "riantr/moonbit_image"

version = "0.3.9"

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

description = "Pure-MoonBit image decoder/encoder covering BMP / QOI / TGA / PNG / GIF / JPEG / ICO / TIFF / FIM with zero external runtime dependencies. Decoders raise a structured `DecodeError` sub-error type so callers can branch on cause (UnsupportedFormat / TruncatedData / InvalidHeader / InvalidValue / EncodeNotImplemented). 0.3.7 re-licensed under MIT only (was `MIT OR Apache-2.0`); see LICENSE-MIT for the full text. 0.3.8 compiles against the current MoonBit core (the `try?` operator was removed upstream) and declares js / wasm-gc support in addition to native. 0.3.9 corrects the release note for 0.3.8; the code is unchanged."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native+js+wasm-gc",
)
