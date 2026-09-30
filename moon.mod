name = "riantr/moonbit_image"

version = "0.3.6"

readme = "README.mbt.md"

repository = "https://github.com/riantr/moonbit-image"

license = "MIT OR Apache-2.0"

keywords = [ "image", "codec", "bmp", "qoi", "tga", "png", "gif", "jpeg", "ico", "tiff", "fim", "xray", "security-scanner", "dual-energy" ]

description = "Pure-MoonBit image decoder/encoder covering BMP / QOI / TGA / PNG / GIF / JPEG / ICO / TIFF / FIM with zero external runtime dependencies. Decoders raise a structured `DecodeError` sub-error type so callers can branch on cause (UnsupportedFormat / TruncatedData / InvalidHeader / InvalidValue / EncodeNotImplemented). 0.3.6 adds FIM: the CETC BVE-series X-ray security-scanner raw detector stream (`.fim`); `decode_fim` returns the two dual-energy halves laid out side by side as an 8-bit Gray8 image, `decode_fim_raw` returns the raw 16-bit GrayA8 detector image, plus header-only `fim_dimensions`, geometry helpers (`fim_split_rows` / `fim_split_cols` / `fim_apply_y_roll` / `fim_find_bright_strip` / `fim_find_auto_y_roll`), grayscale rendering (`fim_to_grayscale8`) and dual-energy ratio renderers (`fim_ratio_grayscale` / `fim_ratio_pseudo_color` / `fim_ratio_pseudo_color_hsb`). Auto-detect via `detect_format`; magic bytes `J A` (0x4A 0x41)."

options(
  warn_list: "",
  preferred_target: "native",
  supported_targets: "+native",
)
