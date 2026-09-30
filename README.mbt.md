# riantr/moonbit_image

Pure-MoonBit image decoder / encoder covering **BMP / QOI / TGA / PNG / GIF / JPEG / ICO / TIFF / FIM**. Zero external runtime dependencies — every codec is hand-written in MoonBit and lives inside this single package.

This package is forked from [`lws/moonbit_image`](https://github.com/Milky2018/moonbit-image) (MIT, 2025). The original sources were vendored inside `moonbit-labeler/extensions/image/`; this package repackages them as a standalone `mooncakes.io` library so the labeler and any other MoonBit project can depend on a single shared implementation.

## What's new in 0.3.6

Adds the **FIM** codec — CETC BVE-series X-ray security-scanner raw detector streams (`.fim`). The `.fim` format is a 230-byte little-endian header followed by a column-major 16-bit little-endian payload; the scanner interleaves the two dual-energy exposures on the time axis, so the even and odd ROWS of the decoded image are the low- and high-energy halves. Zero new dependencies — the decoder uses the package's `Image` / `PixelFormat` / `read_u32_le` primitives and a hand-rolled natural log.

* **`decode_fim(data)`** — display-ready `Image`: the two dual-energy halves laid out side by side (`low | high`, `2*width x height/2`), rendered to 8-bit `Gray8` with the viewer defaults (sRGB degamma, [1, 99] percentile stretch, inverted). One image, no second lookup — a plain image viewer shows both halves at once.
* **`decode_fim_raw(data)`** — the raw detector image as `GrayA8` of size `(width, height)`, two bytes per pixel carrying the 16-bit sample big-endian. No flip, no split, no degamma; downstream code can re-derive whatever it needs.
* **`fim_dimensions(data)`** — header-only `(width, height)` of the detector grid (no pixel decode). Wired into `image_dimensions()` for the unified path.
* **Geometry helpers** (all operate on `GrayA8`):
  * `fim_side_by_side(left, right)` — horizontal join for any matching pixel format.
  * `fim_split_rows(img)` — even rows / odd rows, returning two `(width, height/2)` images.
  * `fim_split_cols(img)` — even columns / odd columns, returning two `(width/2, height)` images (legacy detector-channel split).
  * `fim_apply_y_roll(img, shift_px)` — cyclic vertical roll, matching numpy `roll(shift, axis=0)`.
  * `fim_find_bright_strip(img, air_threshold?)` — bottom-most all-air band, `(top_row, row_count)`.
  * `fim_find_auto_y_roll(img)` — half the bright-strip height, shifted up.
* **Grayscale / dual-energy renderers**:
  * `fim_to_grayscale8(img, invert?, degamma?, percentile_low?, percentile_high?)` — value = sample/65535, optional sRGB degamma (`γ = 2.2`), optional [low, high] percentile stretch, optional invert, byte = `floor(value * 255 + 0.5)`.
  * `fim_ratio_grayscale / fim_ratio_pseudo_color / fim_ratio_pseudo_color_hsb` — dual-energy `R = ln(I0 / I_low) / ln(I0 / I_high)`, gray / palette / HSB pseudo-color respectively. Black where invalid.
* **`detect_format`** recognises the 2-byte `J A` (0x4A 0x41) magic; `image_dimensions` returns the raw detector grid.
* **`ImageFormat::FIM`** added; `is_decodable()` reports `true`. No encoder — `encode(_, FIM)` raises `EncodeNotImplemented`.
* **No `ImageFormat::FIM` requires any of the other codecs to compile** — the new module is self-contained.

## What's new in 0.3.4

Bug-fix release for the JPEG IDCT. The 1-D `idct_1d` routine was
unconditionally adding the +128 level shift and clamping to [0, 255] on
every call, but `idct_2d` runs it twice (row pass + column pass). The
cumulative effect was a +256 shift (clamping almost every pixel to
white) plus a clipped intermediate row pass that the column pass
couldn't recover from — the classic "花屏" 8×8 block pattern visible on
every real-world JPEG in mizchi / backend-decode mode.

The fix splits the row and column passes with explicit flags:
`idct_1d(v, out, os, apply_level_shift, is_final)`. The row pass gets
`false, false`; the column pass gets `true, true`. Level shift and
clamp are now applied exactly once, on the final (column) pass.

Reported by `riantr/moonbit_labeler` mizchi smoke test on the BIOMEDICA
X-ray JPEG set. Same patch applied locally in the consuming project
verified end-to-end before the upstream release.

## What's new in 0.3.3

Patch release — no functional changes from 0.3.2 / 0.3.1. Locking in the
current state after a full benchmark pass on the consuming project
(`riantr/moonbit_labeler`); 49/49 tests pass against this version, and the
`docs/benchmark.md` baseline in moonbit-labeler measures each decoder /
encoder at known reference sizes. The metrics are stable across
re-runs, so 0.3.3 is safe to depend on for downstream production work.

## What's new in 0.3.0

0.3.0 adds two new formats — ICO (Windows icon / cursor container) and TIFF (Tagged Image File Format) — and ships 11 new tests covering them. Every existing 0.2.x test still passes.

* **`decode_ico`** routes ICO entries through the existing BMP / PNG decoders:

  * Full BMP file (with the 14-byte `BM` header) — pass-through.
  * Full PNG file (the Vista+ form) — pass-through.
  * DIB-only BMP (older icons) — a synthetic 14-byte file header is prepended so the existing BMP decoder can take it.

  The largest entry by area (with the first entry as the tie-breaker) is returned.

* **`decode_tiff`** handles baseline uncompressed TIFF only. The supported subset is documented explicitly so callers know what to expect:

  | Field | Supported |
  |---|---|
  | Byte order | `II` (little-endian); `MM` raises `InvalidHeader` |
  | Compression | `1` (none); LZW / Deflate / JPEG-in-TIFF rejected |
  | Photometric | `0` (WhiteIsZero), `1` (BlackIsZero), `2` (RGB), `3` (Palette) |
  | BitsPerSample | 1 / 2 / 4 / 8 / 16 (uniform across samples) |
  | SamplesPerPixel | 1 (greyscale / palette) or 3 (RGB) |
  | PlanarConfiguration | `1` (chunky); planar rejected |
  | Layout | single strip only |
  | Sample format | UINT |

  16-bit samples are right-shifted to 8 bits for output — display-friendly but lossy for photographic TIFFs. The ColorMap tag is read and palette indices are expanded to RGBA8.

* **`detect_format`** recognises both the new magic byte sequences (`II*\0`, `MM\0*` for TIFF; `00 00 01 00 NN …` for ICO).

* **`ImageFormat::is_decodable()`** now reports `true` for both new variants.

## What's new in 0.2.0

0.2.0 is a breaking-API revision that cleans up the public error story and fixes a real chroma-shearing bug in the JPEG decoder.

* **Structured `DecodeError`** replaces the previous stringly-typed `Failure::Failure("...")` errors. Every public decoder / encoder entry point now raises one of:

  | Variant | When it fires |
  |---|---|
  | `DecodeError::UnsupportedFormat(String)` | magic bytes do not match any known format signature |
  | `DecodeError::TruncatedData(String)` | a frame / chunk / scanline ended in the middle of a read |
  | `DecodeError::InvalidHeader(String)` | a header field is out of range or has an unsupported value |
  | `DecodeError::InvalidValue(String)` | a header / pixel-data value was readable but rejected downstream |
  | `DecodeError::EncodeNotImplemented(String)` | `encode()` was called with a decode-only format |

  Callers can `match err { ... }` on the variant, or call `.to_string()` for a one-line diagnostic. The per-codec helpers (`decode_bmp`, `decode_qoi`, …) and low-level byte readers (`read_u32_le`, …) keep raising the built-in `Failure` suberror; the public wrappers translate it.

* **Removed legacy convenience APIs**: `is_supported_format` and `is_encode_supported`. Use the new `ImageFormat::is_decodable() / is_encodable()` instance methods instead — they take an `ImageFormat` and read better in `match` arms:

  ```mbt
  match fmt {
    ImageFormat::BMP => ...
    f if f.is_decodable() => ...
  }
  ```

* **Fixed JPEG chroma positioning bug** (the "花屏" issue): for chroma components in 4:2:0 / 4:2:2 subsampled JPEGs the decoder placed each chroma block at `mx * sf_h * 8` instead of `mx * max_h * 8`, which mis-aligned Cb / Cr against the luma plane and produced visible colour fringing / colour banding on most real-world photos. The chroma sampler now uses the correct macro-grid stride.

* **`Image::to_rgba8` simplified**: removed a redundant early-return-then-match-again structure; the function now uses one `guard` over the source format and a single bulk conversion loop per source layout.

## Why a separate package

`moonbit-labeler` used to vendor the image codec under `extensions/image/`. That works, but every labeler checkout ships its own copy and any other MoonBit project that wants the same decoder has to vendor the sources again. Moving the codec to a dedicated `mooncakes.io` module:

- lets `moonbit-labeler` depend on it via `import "riantr/moonbit_image"`
- lets any other MoonBit project reuse the same decoder / encoder
- isolates the codec under a clean test surface (BMP / QOI round-trip, pixel math, geometric transforms) that isn't tied to the labeler UI

## API surface

```mbt
// one-shot auto-detect decoder; raises DecodeError
pub fn decode(data : Bytes) -> Image raise DecodeError

// header-only dimension read (no pixel decode)
pub fn image_dimensions(data : Bytes) -> (Int, Int, ImageFormat) raise DecodeError

// per-format decoders (still raise the lower-level Failure)
pub fn decode_bmp(data : Bytes) -> Image raise Failure
pub fn decode_qoi(data : Bytes) -> Image raise Failure
pub fn decode_tga(data : Bytes) -> Image raise Failure
pub fn decode_png(data : Bytes) -> Image raise Failure
pub fn decode_gif(data : Bytes) -> Image raise Failure
pub fn decode_jpeg(data : Bytes) -> Image raise Failure
pub fn decode_fim(data : Bytes) -> Image raise Failure            // dual-energy side-by-side, Gray8
pub fn decode_fim_raw(data : Bytes) -> Image raise Failure         // raw 16-bit detector, GrayA8
pub fn fim_dimensions(data : Bytes) -> (Int, Int) raise Failure    // raw detector (width, height)

// FIM geometry helpers (GrayA8 in, GrayA8 out)
pub fn fim_side_by_side(left : Image, right : Image) -> Image raise Failure
pub fn fim_split_rows(img : Image) -> (Image, Image) raise Failure
pub fn fim_split_cols(img : Image) -> (Image, Image) raise Failure
pub fn fim_apply_y_roll(img : Image, shift_px : Int) -> Image raise Failure
pub fn fim_find_bright_strip(img : Image, air_threshold? : Double = 50000.0) -> (Int, Int) raise Failure
pub fn fim_find_auto_y_roll(img : Image) -> Int raise Failure

// FIM renderers
pub fn fim_to_grayscale8(img : Image, invert? : Bool = true, degamma? : Bool = false,
                         percentile_low? : Double? = Some(1.0),
                         percentile_high? : Double? = Some(99.0)) -> Image raise Failure
pub fn fim_ratio_grayscale(low : Image, high : Image) -> Image raise Failure
pub fn fim_ratio_pseudo_color(low : Image, high : Image) -> Image raise Failure
pub fn fim_ratio_pseudo_color_hsb(low : Image, high : Image) -> Image raise Failure

// writers (QOI + BMP only); encode() raises DecodeError::EncodeNotImplemented
// for everything else (including FIM)
pub fn encode(image : Image, format : ImageFormat) -> Bytes raise DecodeError
pub fn encode_qoi(image : Image) -> Bytes raise Failure
pub fn encode_bmp(image : Image) -> Bytes raise Failure
```

`Image` is `{ width, height, format, data }` where `format` is one of `Gray8 / GrayA8 / RGB8 / RGBA8`. The `Color` struct, `Image::to_rgba8 / to_grayscale / flip_horizontal / rotate_* / resize_* / brighten / histogram / average_color`, and the color-space conversion methods on `Color` (`to_hsl / from_hsl / to_hsv / from_hsv / blend / lerp / distance / to_gray`) are all available.

## Quick start

```mbt
// decode a JPEG -> Image, resize, re-encode as QOI
let img  = @moonbit_image.decode(jpeg_bytes) catch {
  err => {
    @log.warn("decode failed: \{err}")
    abort("give up")
  }
}
let half = img.resize_nearest(img.width / 2, img.height / 2)
let qoi  = @moonbit_image.encode(half, ImageFormat::QOI)
```

## Tests

`moon test --target native` runs the white-box tests in `lib_test.mbt` (29 tests across format detection, header reading, decode round-trips for QOI + BMP, colour math, geometric transforms, and a fuzz sweep over random pixels / random crops). Black-box tests live in `qa/`.

## License

Dual-licensed under **MIT or Apache-2.0**, at your option.

The image codec sources in this package were originally published by lws as [`moonbit_image`](https://github.com/Milky2018/moonbit-image) under the MIT license. To stay compatible with that upstream, this package keeps the MIT grant; we additionally offer Apache-2.0 so downstream consumers can pick whichever license fits their project. See `LICENSE-MIT` and `LICENSE-APACHE` for the full texts.

## Attribution

- Original sources © 2025 lws, MIT — see upstream history at https://github.com/Milky2018/moonbit-image.
- 0.2.0 revisions (DecodeError, JPEG chroma fix, API cleanup) © 2026 RiantR, MIT or Apache-2.0.