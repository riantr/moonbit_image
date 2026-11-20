# riantr/moonbit_image

Pure-MoonBit image decoder / encoder covering **BMP / QOI / TGA / PNG / GIF / JPEG / ICO / TIFF / FIM**. Zero external runtime dependencies — every codec is implemented in MoonBit and lives inside this single package.

This package is forked from [`lws/moonbit_image`](https://github.com/Milky2018/moonbit-image) (MIT, 2025). The original sources were vendored inside `moonbit-labeler/extensions/image/`; this package repackages them as a standalone `mooncakes.io` library so the labeler and any other MoonBit project can depend on a single shared implementation.

## What's new in 0.3.14

**A QA pass found and fixed an out-of-bounds defect in every decoder.**

The package went through a static analysis pass and then a malformed-input
sweep: 28 080 deliberately corrupted images — truncations, single flipped header
bytes, oversized dimension fields, random noise — fed to the decoders.
**1 311 of them crashed the 0.3.13 release.** The patched tree crashes on none
of them.

The root cause was one pattern, repeated across the codecs. The decoders read
dimensions, offsets and table sizes out of the file into an `Int32`, and an
`Int32` overflow — or a `u32` above 2³¹ read into a signed field — produces a
**negative** number. A negative offset passes every bounds check that compares it
against a length, so the read or write that follows goes out of bounds. A
corrupt header turned into a panic in somebody else's image pipeline.

Six classes of defect, all fixed here:

| # | Defect | Where |
|---|---|---|
| 1 | A `u32` above 2³¹ read into a signed `Int32` came back negative | `utils.mbt` |
| 2 | Bounds checks whose own arithmetic overflowed an `Int32` | `bmp.mbt`, `tga.mbt`, `ico.mbt`, `tiff.mbt`, `png.mbt` |
| 3 | Allocation sizes computed from file-derived dimensions overflowed | `bmp.mbt`, `tga.mbt`, `qoi.mbt`, `png.mbt`, `tiff.mbt`, `fim.mbt` |
| 4 | Reads with no bounds check at all | the GIF colour tables, the JPEG marker loop |
| 5 | An unchecked write destination in the BMP RLE decoders | `bmp.mbt` |
| 6 | The JPEG decoder trusted the *contents* of each segment | `jpeg.mbt` |

The fix adds `checked_mul`, a `MAX_DECODE_PIXELS` cap (2²⁷ pixels — the same cap
the reference implementation uses) and `check_decode_size`, rewrites every region
check into `Int64` or difference form, and adds the bounds checks that were
missing. The four fields that are *not* sizes — the BMP height (signed by the
specification), the PNG chunk CRC, the ICO DIB height and TIFF tag values — are
now read as raw bit patterns through a separate `read_u32_bits_*` pair, so they
are no longer rejected for being "too large".

**Two more bugs surfaced while writing the regression test.**

* **The GIF graphic-control extension was read one byte too far.** The block is
  six bytes — size, packed field, delay, transparent index, terminator — and the
  check asked for five, so a file that ends right after the transparent index
  passed the check and the terminator read went past the end of the buffer. Only
  `decode_gif_all`, the animation path, reaches that code.
* **The Quick start below did not compile for a consumer.** `PixelFormat` and
  `ImageFormat` were `pub enum`, which makes their variants read-only outside
  the defining package, so an external project could not write
  `ImageFormat::QOI`. They are `pub(all)` now, which is purely additive: the
  variants were already writable inside the package.

**The package now ships a malformed-input regression test.** `fuzz_test.mbt` is
new. It embeds the `testdata/` fixtures, mutates them deterministically and
feeds every mutation to every decoder; a panic fails the test. It is native-only
(see the `options` block in `moon.pkg`), and `moon test --target native` now runs
**145 tests** in about three seconds.

The test has teeth: run against the unpatched 0.3.13 sources it crashes, and
against 0.3.14 it passes. The sweep it is built on now also covers
`decode_gif_all`, the animation path, which the original pass did not reach —
that is how the graphic-control bug above was found. Over the full corpus —
28 080 mutated inputs across all 21 fixtures, through `decode`,
`image_dimensions` and `decode_gif_all` — the patched tree reports zero
crashes.

**The codec output is unchanged.** Every fix is a bounds check or a rejection of
a malformed header; no decoder produces different pixels for a valid file. The
speed and quality figures in the 0.3.13 notes below were re-measured for this
release and updated where they had drifted.

**This release also corrects the documentation.** The claims below were checked
against the code and a number of them did not survive: the TIFF support table
was stale, two `DecodeError` variants were documented as active when nothing
raises them, the API surface was missing five public functions and gave the
wrong integer type in five signatures, the test inventory described a fuzz sweep
that did not exist, and the JPEG byte-count comparison quoted numbers that do
not reproduce. All of them are fixed in this release.

## What's new in 0.3.13

**This release is the result of a speed and quality comparison against the
reference implementation, `mizchi/image`.**

The codecs here were written from scratch, so the question "are we as good as
the reference?" needed an answer that was measured rather than asserted. Two
harnesses now do that, both under `.tools/` (a dot-directory, so nothing of
them is published):

* `.tools/cross_check_encoders.py` — encodes the same images with these
  encoders, with the independent `mizchi/image` encoders and, as the
  tie-breaker, with Pillow, then compares the *decoded pixels*. 84
  image/format pairs, zero failures.
* `.tools/bench_encoders.py` — measures encode and decode wall time against
  `mizchi/image`, and the size of what each side writes.

**The comparison found two real bugs, both fixed here.**

* **The TIFF decoder could not read a TIFF that `mizchi/image` wrote.** The
  decoder only accepted uncompressed, single-strip files, so every LZW or
  Deflate TIFF from another writer was rejected outright. The decoder now
  handles compression 1, 5 (LZW), 8 / 32946 (Deflate) and 32773 (PackBits),
  multiple strips, and the horizontal differencing predictor. Files in both
  directions now decode.
* **The GIF encoder wrote corrupt files once the LZW table filled up.** The
  table was never cleared at the clear code, so the encoder kept handing out
  codes that the decoder read as different strings. A 256×256 image with more
  than 4096 distinct strings produced a file that Pillow could not open. The
  table is now emptied with the clear code, as the format requires.

The GIF encoder also got a k-d tree for the palette lookup, which replaced a
linear scan over the palette for every pixel.

**The JPEG decoder is about six times faster, and closer to the reference
output.**

* The inverse DCT is now the AAN butterfly — the factorisation libjpeg uses —
  instead of a direct 8×8 matrix product. The butterfly computes the
  transform up to a per-frequency diagonal, which is cancelled for free by
  folding it into the quantisation table.
* The Huffman decoder reads the next eight bits at once through a lookup
  table, instead of one bit at a time, and the bit reader keeps its bits in
  an accumulator instead of copying itself on every read.
* Decoding a block allocates nothing: the scratch buffers belong to the
  caller.

Measured against `mizchi/image` on 256×256 images, the JPEG decode went from
**18.9× slower to 3.3× slower**, and the decoded pixels are *closer* to
Pillow's than before: on the 64×64 natural sample, 6 of the first 24 bytes of
the decoded RGB output now differ from Pillow's, against 13 before, and the
largest of those differences is 2 instead of 3.

**The TIFF encoder writes compressed files now.**

It writes LZW-compressed strips with the horizontal differencing predictor,
like the reference does. A 256×256 RGB image went from 786 894 bytes
uncompressed to 297 460 — the reference writes 286 382 for the same image.
The compression costs about 2.3× the reference's encode time.

**The PNG inflater was rewritten** around a stream-order Huffman table and a
local bit buffer, which took the PNG decode from 7.4× slower than the
reference to 4.0×.

**The JPEG encoder** now uses a flattened cosine table and allocates nothing
per block, which took about a fifth off its encode time.

**What is still slower, and why.**

The reference's PNG codec delegates to a MoonBit port of zlib, and its JPEG
codec uses hand-written SIMD on wasm. On native both sides are scalar, and
these gaps remain: PNG encode 1.8×, PNG decode 4.0×, GIF decode 5.1×, TIFF
decode 2.1×, ICO decode 3.4×, JPEG decode 3.3×, JPEG encode 7.4×, TIFF
encode 2.3×. The JPEG encoder is the largest one: the reference uses
libjpeg's integer "islow" forward DCT, while this package uses a
floating-point separable one.

The GIF encoder deserves a note. The reference refuses any image with more
than 256 distinct colours; this package quantises them with a median cut
instead. On the one image both sides can encode, the outputs are the same
size and this encoder takes about 2.6× longer. The per-image average of a
whole benchmark run is an artefact of that: two of the three benchmark
images are ones the reference rejects, so the average counts work the
reference never does.

**Quality is unchanged: on every image and every format, this package is not
measurably further from the source than the reference encoder is.**

## What's new in 0.3.12

**The released package no longer carries the release CI's own log files.**

`moon publish` packages the whole module directory, so the two log files the
release workflow writes next to the sources — `dryrun.log` and `publish.log` —
ended up inside the published archive: 147 KiB of compiler warnings and the
publish output, in a package that consumers download for its codecs. (They
contain no credentials — the token is never printed — but they are noise.)

The workflow now writes both logs to `$RUNNER_TEMP`, outside the checkout, and
`.gitignore` excludes `*.log` as a second line of defence: `moon publish`
leaves ignored files out of the archive, which is the same mechanism that
already keeps `pkg.generated.mbti` out of it.

No code change: the codecs of 0.3.11 are the codecs of 0.3.12.

## What's new in 0.3.11

**Six new encoders, written from scratch: PNG, GIF, JPEG, TGA, ICO and TIFF.**

Until 0.3.10 this package could only *write* QOI and BMP; every other format
was decode-only and `encode()` raised `DecodeError::EncodeNotImplemented` for
it. 0.3.11 adds an encoder for six of the seven remaining decodable formats.
FIM stays decode-only — it is a detector stream, not a picture format.

Every encoder is implemented in MoonBit inside this package. There is no
compression library, no FFI and no new dependency: the DEFLATE compressor, the
GIF LZW compressor, the JPEG forward DCT and the Huffman tables are all
written here.

| Format | Entry point | What it writes |
|---|---|---|
| PNG | `encode_png` | 8-bit Gray / Gray+Alpha / RGB / RGBA, colour type taken from the pixel format, five row filters chosen by the minimal-absolute-sum heuristic, hand-written DEFLATE (fixed Huffman + LZ77 with a 32 KiB window) |
| GIF | `encode_gif` | GIF89a, one frame, global colour table, binary transparency, LZW; exact palette when the image has few enough colours, median-cut quantisation otherwise |
| JPEG | `encode_jpeg(image, quality)` | baseline sequential (SOF0), JFIF APP0, 4:4:4 (no chroma subsampling), Annex K quantisation and Huffman tables, 8-point forward DCT; JPEG has no alpha channel, so alpha is dropped |
| TGA | `encode_tga` / `encode_tga_rle` | types 2 / 3 (uncompressed) and types 10 / 11 (run-length encoded), 24-bit BGR or 32-bit BGRA |
| ICO | `encode_ico` | `ICONDIR` + one 16-byte directory entry + a DIB-only payload (`BITMAPINFOHEADER`, bottom-up BGRA XOR bitmap, 1-bpp AND mask padded to 4 bytes) |
| TIFF | `encode_tiff` | little-endian (`II`), LZW-compressed strips with the horizontal differencing predictor; 1 sample for gray, 3 for RGB, 4 for RGBA (`ExtraSamples = 2`) |

`encode(img, format)` dispatches to all eight encoders (JPEG at quality 85),
and `ImageFormat::is_encodable()` now reports `true` for BMP, QOI, TGA, PNG,
GIF, JPEG, ICO and TIFF.

**Three decoder bugs that the new encoders exposed.**

Writing an encoder is also a way of testing a decoder, and three shipping bugs
turned up. All three are fixed here:

* **The JPEG decoder transposed every 8×8 block.** The inverse DCT kept its
  intermediate in a transposed layout and wrote the result back transposed as
  well, so every decoded JPEG was mirrored in 8×8 tiles. Straight against
  transposed, the error was 5048 versus 70 — and Pillow disagreed with the
  decoder on every non-trivial image. The luma now agrees with libjpeg within
  1–5 units; the chroma still differs, because this decoder upsamples
  nearest-neighbour while libjpeg uses a triangular filter.
* **The PNG inflater lost the tail of the stream.** `BitReader::read_bits`
  raises when the stream runs out and drops the bits it had already
  consumed, so the last DEFLATE symbol went missing whenever the final
  padding was shorter than the longest Huffman code (9 bits for the fixed
  table). A 12×9 PNG that Pillow reads perfectly failed with
  `DEFLATE: bad lit code`. The short read now returns the bits that were
  actually available instead of raising.
* **The ICO decoder read DIB-only entries at double height.** An icon's DIB
  covers the XOR bitmap *and* the AND mask, so `biHeight` is twice the icon
  height — and the BMP decoder took it for the image height.

A fourth, smaller one: the TIFF decoder rejected 4-sample RGB files, so a
TIFF with an alpha channel could not be read at all. It now accepts
`photometric = 2` with 3 or 4 samples and reports RGBA8 for the latter.

**How the encoders were verified.**

`.tools/cross_check_encoders.py` encodes the same images with these encoders,
with the independent `mizchi/image` encoders and, as the tie-breaker, with
Pillow — and compares the *decoded pixels*, because two implementations of the
same compression never agree on the bytes. The package's own decoders are
checked against Pillow too, which is how the JPEG transposition was found: the
package's own tests only asserted dimensions and pixel format, never the
pixels themselves.

The current run is 84 image/format pairs with zero failures. Two differences
are documented rather than "fixed": the JPEG chroma upsampling described
above, and the GIF palette, where a different quantiser legitimately picks
different colours — the check is that ours is never measurably further from
the source image than the reference encoder's.

## What's new in 0.3.10

**`detect_format()` no longer crashes on TGA files that carry a v2 footer.**

`detect_tga()` scanned the 17-byte `TRUEVISION-XFILE.` footer signature with
a hard-coded 18-byte loop, so the last iteration indexed one byte past the
end of the signature and panicked with an out-of-bounds access. Every TGA
file with the standard v2 footer hit it — including all three samples under
`testdata/tga/` — which meant `detect_format()` and `decode()` aborted
instead of returning an image. The bounds are now derived from the
signature's own length, and the reserved byte that follows the signature is
accounted for when the footer offset is computed.

The bug dates back to the vendored import and was never covered by a test.

**Decode tests for JPEG, PNG, GIF and TGA.** Those four codecs had no
`decode_*` coverage at all; the suite only exercised ICO, TIFF and FIM
through a decode entry point. `lib_test_codecs.mbt` adds 25 tests over the
real `testdata/` samples — PNG (1×1 RGBA, 16×16 indexed → RGBA8, 32×32 RGBA),
GIF (1×1, 32×32, plus the 8×8 animated sample through `decode_gif_all`),
TGA (1×1 24-bit, 32×32 grayscale → Gray8, 32×32 RGBA) and JPEG (1×1 plus two
64×64 baseline samples) — together with the unified `decode()` routing, the
`image_dimensions()` fast path and the `is_decodable()` matrix for all nine
formats. The test suite goes from 43 to 70 tests.

## What's new in 0.3.9

Documentation-only release. The code is byte-identical to 0.3.8.

The 0.3.8 release note said that 0.3.7 used the removed `try?` operator "in
six places". The count was wrong: there are seven - five in `lib.mbt` and two
in `lib_test.mbt`. The note no longer states a count, and it now says how to
reproduce the breakage instead.

## What's new in 0.3.8

Two independent fixes, no change to the decoding behaviour.

**The package compiles against the current MoonBit core again.** The core
removed the `try?` operator, and 0.3.7 used it in `lib.mbt` and
`lib_test.mbt` — so a `moon add riantr/moonbit_image@0.3.7` against a current
toolchain resolved to a package that did not compile. 0.3.8 rewrites those
sites as `expr catch { e => Err(e) }`, which is the same expression the core
now expects. The error surface is unchanged: `decode` still raises
`DecodeError::UnsupportedFormat` for an unknown magic and
`DecodeError::InvalidHeader` for a broken header, and the same 43 tests pass.

To see the breakage for yourself, unpack the published 0.3.7 archive and run
`moon check` in it: it fails with `Error: [3002] try? has been removed`.

**js and wasm-gc are supported targets, not just native.** 0.3.7 declared
`supported_targets = "native"`, so any project building for the browser or
for wasm could not depend on it — the consumer had to vendor a copy of the
sources instead. This package is pure MoonBit with no FFI, so there was never
a technical reason for the restriction. 0.3.8 declares
`+native+js+wasm-gc`, and the release CI type-checks all three targets before
it publishes.

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

* **`decode_tiff`** handles baseline TIFF. The supported subset in **0.3.0** was deliberately narrow, and it has grown since — 0.3.13 added LZW, PackBits and Deflate, multiple strips and the horizontal predictor. The current subset is:

  | Field | Supported |
  |---|---|
  | Byte order | `II` (little-endian); `MM` raises `InvalidHeader` |
  | Compression | `1` (none), `5` (LZW), `8` / `32946` (Deflate), `32773` (PackBits) |
  | Predictor | `1` (none), `2` (horizontal differencing) |
  | Photometric | `0` (WhiteIsZero), `1` (BlackIsZero), `2` (RGB), `3` (Palette) |
  | BitsPerSample | 1 / 2 / 4 / 8 / 16 (uniform across samples) |
  | SamplesPerPixel | 1 (greyscale / palette), 3 (RGB) or 4 (RGBA) |
  | PlanarConfiguration | `1` (chunky); planar rejected |
  | Layout | one or more strips; every strip is decompressed on its own |
  | Sample format | UINT |

  16-bit samples are right-shifted to 8 bits for output — display-friendly but lossy for photographic TIFFs. The ColorMap tag is read and palette indices are expanded to RGBA8.

  One inconsistency is worth knowing about: `detect_format` recognises *both*
  byte orders (`II*\0` and `MM\0*`) and reports `TIFF` for either, but the
  decoder only reads little-endian files, so a big-endian TIFF is detected and
  then rejected with `InvalidHeader`.

* **`detect_format`** recognises both the new magic byte sequences (`II*\0`, `MM\0*` for TIFF; `00 00 01 00 NN …` for ICO).

* **`ImageFormat::is_decodable()`** now reports `true` for both new variants.

## What's new in 0.2.0

0.2.0 is a breaking-API revision that cleans up the public error story and fixes a real chroma-shearing bug in the JPEG decoder.

* **Structured `DecodeError`** replaces the previous stringly-typed `Failure::Failure("...")` errors. Every public decoder / encoder entry point now raises one of:

  | Variant | When it fires |
  |---|---|
  | `DecodeError::UnsupportedFormat(String)` | magic bytes do not match any known format signature |
  | `DecodeError::TruncatedData(String)` | *reserved* — no codec raises it yet |
  | `DecodeError::InvalidHeader(String)` | a header field is out of range or has an unsupported value; this is what every codec-level `Failure` is wrapped as |
  | `DecodeError::InvalidValue(String)` | *reserved* — no codec raises it yet |
  | `DecodeError::EncodeNotImplemented(String)` | `encode()` was called with a decode-only format |

  Callers can `match err { ... }` on the variant to branch on the cause; each variant carries its own `String` payload with the diagnostic message. (`DecodeError` does not implement `Show` / `to_string()`, so build the message from the matched payload.) The per-codec helpers (`decode_bmp`, `decode_qoi`, …) and low-level byte readers (`read_u32_le`, …) keep raising the built-in `Failure` suberror; the public wrappers translate it. `TruncatedData` and `InvalidValue` are kept so downstream callers can match exhaustively without churn, but nothing raises them today — a truncated file is reported as `InvalidHeader`.

* **Removed legacy convenience APIs**: `is_supported_format` and `is_encode_supported`. Use the new `ImageFormat::is_decodable() / is_encodable()` instance methods instead — they take an `ImageFormat` and read better in `match` arms:

  ```mbt nocheck
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

```mbt nocheck
// format sniffing; None when the magic bytes match nothing
pub fn detect_format(data : Bytes) -> ImageFormat?

// one-shot auto-detect decoder; raises DecodeError
pub fn decode(data : Bytes) -> Image raise DecodeError

// decode a file whose format is already known; skips the sniffing step
pub fn decode_by_format(data : Bytes, format : ImageFormat) -> Image raise DecodeError

// header-only dimension read (no pixel decode)
pub fn image_dimensions(data : Bytes) -> (Int32, Int32, ImageFormat) raise DecodeError

// per-format decoders (still raise the lower-level Failure)
pub fn decode_bmp(data : Bytes) -> Image raise Failure
pub fn decode_qoi(data : Bytes) -> Image raise Failure
pub fn decode_tga(data : Bytes) -> Image raise Failure
pub fn decode_png(data : Bytes) -> Image raise Failure
pub fn decode_gif(data : Bytes) -> Image raise Failure
pub fn decode_jpeg(data : Bytes) -> Image raise Failure
pub fn decode_ico(data : Bytes) -> Image raise Failure
pub fn decode_tiff(data : Bytes) -> Image raise Failure
pub fn decode_fim(data : Bytes) -> Image raise Failure            // dual-energy side-by-side, Gray8
pub fn decode_fim_raw(data : Bytes) -> Image raise Failure         // raw 16-bit detector, GrayA8
pub fn fim_dimensions(data : Bytes) -> (Int32, Int32) raise Failure    // raw detector (width, height)

// the GIF animation path: every frame, composited onto the logical screen
pub fn decode_gif_all(data : Bytes) -> AnimatedImage raise Failure

// FIM geometry helpers (GrayA8 in, GrayA8 out)
pub fn fim_side_by_side(left : Image, right : Image) -> Image raise Failure
pub fn fim_split_rows(img : Image) -> (Image, Image) raise Failure
pub fn fim_split_cols(img : Image) -> (Image, Image) raise Failure
pub fn fim_apply_y_roll(img : Image, shift_px : Int32) -> Image raise Failure
pub fn fim_find_bright_strip(img : Image, air_threshold? : Double = 50000.0) -> (Int32, Int32) raise Failure
pub fn fim_find_auto_y_roll(img : Image) -> Int32 raise Failure

// FIM renderers
pub fn fim_to_grayscale8(img : Image, invert? : Bool = true, degamma? : Bool = false,
                         percentile_low? : Double? = Some(1.0),
                         percentile_high? : Double? = Some(99.0)) -> Image raise Failure
pub fn fim_ratio_grayscale(low : Image, high : Image) -> Image raise Failure
pub fn fim_ratio_pseudo_color(low : Image, high : Image) -> Image raise Failure
pub fn fim_ratio_pseudo_color_hsb(low : Image, high : Image) -> Image raise Failure

// writers (QOI, BMP, PNG, GIF, JPEG, TGA, ICO, TIFF); encode() raises
// DecodeError::EncodeNotImplemented for FIM only
pub fn encode(image : Image, format : ImageFormat) -> Bytes raise DecodeError
pub fn encode_qoi(image : Image) -> Bytes raise Failure
pub fn encode_bmp(image : Image) -> Bytes raise Failure
pub fn encode_png(image : Image) -> Bytes raise Failure
pub fn encode_gif(image : Image) -> Bytes raise Failure
pub fn encode_jpeg(image : Image, quality : Int32) -> Bytes raise Failure
pub fn encode_tga(image : Image) -> Bytes raise Failure
pub fn encode_tga_rle(image : Image) -> Bytes raise Failure
pub fn encode_ico(image : Image) -> Bytes raise Failure
pub fn encode_tiff(image : Image) -> Bytes raise Failure
```

`Image` is `{ width, height, format, data }` where `format` is one of `Gray8 / GrayA8 / RGB8 / RGBA8`. The `Color` struct, `Image::to_rgba8 / to_grayscale / flip_horizontal / rotate_* / resize_* / brighten / histogram / average_color`, and the color-space conversion methods on `Color` (`to_hsl / from_hsl / to_hsv / from_hsv / blend / lerp / distance / to_gray`) are all available.

`PixelFormat` and `ImageFormat` are `pub(all)`, so their variants can be
constructed from outside the package — `ImageFormat::QOI` works in a consumer's
own code, not just inside this one.

One caveat about `image_dimensions`: it is a header-only read for BMP, QOI, TGA,
PNG, GIF, JPEG and FIM, but **ICO and TIFF have to walk their directory**, so
for those two it falls back to a full decode and is not the fast path its name
suggests.

## Quick start

```mbt nocheck
// decode a JPEG -> Image, resize, re-encode as QOI

///|
let img = @moonbit_image.decode(jpeg_bytes) catch {
  err => {
    @log.warn("decode failed: \{err}")
    abort("give up")
  }
}

///|
let half = img.resize_nearest(img.width / 2, img.height / 2)

///|
let qoi = @moonbit_image.encode(half, @moonbit_image.ImageFormat::QOI)
```

The enum variants are written through the package name here on purpose:
`ImageFormat` is `pub(all)`, so `@moonbit_image.ImageFormat::QOI` is how a
consumer names it. (Before 0.3.14 the enums were `pub`, which made every
variant read-only outside the package — this example did not compile.)

## Tests

`moon test --target native` runs four test files, **145 tests** in total:

* **`lib_test.mbt`** (45 tests) — format detection for all 9 codecs, header reading, decode round-trips for QOI + BMP, ICO / TIFF / FIM decode, colour math and geometric transforms.
* **`lib_test_codecs.mbt`** (25 tests) — decode coverage for the four codecs that previously had none: JPEG (1×1 plus two 64×64 baseline samples), PNG (1×1 RGBA, 16×16 indexed → RGBA8, 32×32 RGBA), GIF (1×1, 32×32, plus the 8×8 animated sample through `decode_gif_all`), and TGA (1×1 24-bit, 32×32 grayscale → Gray8, 32×32 RGBA). Covers the unified `decode()` routing and the `image_dimensions()` fast path for each, and pins the leading pixel bytes of every sample.
* **`lib_test_writers.mbt`** (61 tests) — the encoders: an encode → own-decoder round trip for every format that can be written, the file structure of each container (PNG signature, GIF header and trailer, JPEG markers, ICO directory, TIFF tags), the edge cases (1×1, 1×7, 7×1, 12×9, 13×9, 33×17, zero-sized images) and the regression tests for the bugs listed above.
* **`fuzz_test.mbt`** (14 tests, native-only) — the malformed-input regression net added in 0.3.14. It embeds the `testdata/` fixtures, mutates them deterministically and feeds every mutation to `decode`, `image_dimensions` and `decode_gif_all`; a panic fails the test. One test per defect class pins the exact header that used to crash.

`lib_test_codecs.mbt` and `fuzz_test.mbt` embed the real `testdata/` samples as byte-for-byte literals, so the suite needs no filesystem access at run time. `lib_test_codecs.mbt` is generated by `.tools/gen_codec_tests.py` — re-run that script (it invokes `moon fmt` itself) whenever a sample in `testdata/` changes. `.tools/mutation_check.py` breaks one codec at a time on a scratch copy of the tree and asserts that the suite catches every mutation; it is the evidence that these tests actually discriminate. Both scripts live under `.tools/` so that `moon publish` leaves them out of the released package while they stay tracked in git.

`.tools/cross_check_encoders.py` is the cross-implementation check described in the 0.3.11 notes: it builds a throwaway project that depends on this package *and* on `mizchi/image`, encodes the same images with both, and compares the decoded pixels against Pillow. It is a separate script rather than a test in the package precisely because this package ships with zero external runtime dependencies — `mizchi/image` must never enter the dependency graph of the published module, so the comparison happens outside it.

`.tools/bench_encoders.py` is its speed counterpart, added in 0.3.13: it measures the encode and decode wall time of both implementations on the same images, and the size of what each side writes. Both harnesses share the same rule — the reference implementation's own output is the fixture the two decoders read, so both decoders see identical bytes.

The PNG / GIF / TGA golden pixel values are byte-identical to a reference decode of the same files. The JPEG ones are this decoder's own deterministic output: the samples are 4:2:0 and this decoder upsamples chroma nearest-neighbour, while libjpeg uses "fancy" triangular upsampling, so the chroma channels differ from libjpeg by a few units. Both are valid 4:2:0 decodes.

## License

Licensed under the **MIT License**. See `LICENSE-MIT` for the full
text. (Prior to 0.3.7 this package was dual-licensed `MIT OR
Apache-2.0`; the Apache-2.0 grant was dropped in 0.3.7 because
none of the source files had any upstream Apache-2.0 or GPL/BSD
ancestry — all code is either original (© 2025 lws, MIT) or new
revisions (© 2026 RiantR, MIT), so a single MIT grant covers the
whole work.)

The image codec sources in this package were originally published by
lws as [`moonbit_image`](https://github.com/Milky2018/moonbit-image)
under the MIT license.

## Attribution

- Original sources © 2025 lws, MIT — see upstream history at https://github.com/Milky2018/moonbit-image.
- 0.2.0 revisions (DecodeError, JPEG chroma fix, API cleanup) © 2026 RiantR, MIT.
- 0.3.7 license consolidation (drop Apache-2.0 dual grant) © 2026 RiantR, MIT.
- 0.3.8 core compatibility (`try?` removal) and js / wasm-gc targets © 2026 RiantR, MIT.
- 0.3.10 TGA v2-footer detection fix and the JPEG / PNG / GIF / TGA decode tests © 2026 RiantR, MIT.
- 0.3.11 the PNG / GIF / JPEG / TGA / ICO / TIFF encoders, the JPEG / PNG / ICO / TIFF decoder fixes and the cross-implementation check © 2026 RiantR, MIT.
- 0.3.13 the speed and quality comparison against `mizchi/image`, the AAN inverse DCT and the fast Huffman decoder, the TIFF LZW / PackBits / Deflate decoder and LZW encoder, the GIF encoder fixes and the speed benchmark © 2026 RiantR, MIT.
- 0.3.14 the malformed-input hardening of every decoder, the `pub(all)` enums and the `fuzz_test.mbt` regression net © 2026 RiantR, MIT.