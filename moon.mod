name = "riantr/moonbit_image"

version = "0.3.5"

readme = "README.mbt.md"

repository = "https://github.com/riantr/moonbit-image"

license = "MIT OR Apache-2.0"

keywords = [ "image", "codec", "bmp", "qoi", "tga", "png", "gif", "jpeg" ]

description = "Pure-MoonBit image decoder/encoder covering BMP / QOI / TGA / PNG / GIF / JPEG with zero external runtime dependencies. Decoders raise a structured `DecodeError` sub-error type so callers can branch on cause (UnsupportedFormat / TruncatedData / InvalidHeader / InvalidValue / EncodeNotImplemented)."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native",
)
