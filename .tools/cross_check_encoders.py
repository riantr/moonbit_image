#!/usr/bin/env python3
"""Cross-check moonbit_image's encoders against mizchi/image.

The encoders in this package are written from scratch; `mizchi/image`
(mizchi/image@0.5.0 on mooncakes.io) is an independent implementation of
the same formats. This script encodes the same images with both and
compares the results, which is the only way to know that a from-scratch
codec agrees with the rest of the world.

Why this is a separate script and not a test in the package: `mizchi/image`
is a third-party dependency, and this package deliberately ships with zero
external runtime dependencies. The comparison therefore happens outside
the package, in a throwaway project that depends on both.

How it works:

  1. A throwaway MoonBit project is created with TWO dependencies:
       - `mizchi/image` from the registry (the reference implementation)
       - `local_image`, a copy of this package's runtime sources
         (the implementation under test)
  2. A generated driver encodes a fixed set of images with both
     implementations and prints the results as hex.
  3. Python decodes both outputs with Pillow (a third, independent
     implementation) and compares the pixels.

For lossless formats the pixels must match exactly. For lossy formats
(JPEG) they must match within a small tolerance, and the file sizes are
reported for comparison.

Usage:

    python .tools/cross_check_encoders.py            # all formats
    python .tools/cross_check_encoders.py png        # one format
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOON = "moon.exe" if sys.platform == "win32" else "moon"

# Runtime sources of the package under test. Test files are excluded: the
# copy is a library, and the driver's own code drives the comparison.
RUNTIME_SOURCES = [
    "bmp.mbt", "bmp_writer.mbt", "color.mbt", "deflate.mbt", "fim.mbt",
    "gif.mbt", "gif_writer.mbt", "ico.mbt", "ico_writer.mbt", "jpeg.mbt",
    "jpeg_writer.mbt", "lib.mbt", "png.mbt", "png_writer.mbt", "qoi.mbt",
    "qoi_writer.mbt", "tga.mbt", "tga_writer.mbt", "tiff.mbt",
    "tiff_writer.mbt", "transform.mbt", "types.mbt", "utils.mbt",
]

# The formats to compare, and how tolerant the comparison is.
#   compare = "theirs" - the decoded pixels must be identical, because
#               both encoders keep the exact colours (lossless formats).
#   compare = "source" - both encoders are compared against the source
#               image, because the format is lossy (JPEG).
#   compare = "gif"    - the decoded pixels are compared against the
#               source image, modelling GIF's binary transparency, and
#               against the reference encoder's output.
#
# `theirs` is None for formats that mizchi/image does not implement an
# encoder for; those are checked against the source image instead.
#
# `mine_args` / `theirs_args` are extra arguments appended after the
# image, because the two encoders do not have the same signatures.
#
# `decoder_limit` is how far the package's own decoder may differ from
# Pillow when it reads the package's own output back: 0 for a lossless
# format, more for a lossy one.
FORMATS = {
    "png": {"mine": "encode_png", "theirs": "encode_png",
            "compare": "theirs", "decoder": "decode_png"},
    "gif": {"mine": "encode_gif", "theirs": "encode_gif", "compare": "gif",
            "alpha_below": 128, "decoder": "decode_gif"},
    "jpeg": {"mine": "encode_jpeg", "theirs": "encode_jpeg", "compare": "source",
             "mine_args": ", 90", "theirs_args": ", quality=90",
             "no_alpha": True, "decoder_limit": 8, "decoder": "decode_jpeg"},
    "tga": {"mine": "encode_tga", "theirs": None, "compare": "theirs",
            "decoder": "decode_tga"},
    "tga_rle": {"mine": "encode_tga_rle", "theirs": None, "compare": "theirs",
                "decoder": "decode_tga"},
    "ico": {"mine": "encode_ico", "theirs": "encode_ico", "compare": "theirs",
            "decoder": "decode_ico"},
    "tiff": {"mine": "encode_tiff", "theirs": "encode_tiff", "compare": "theirs",
             "decoder": "decode_tiff"},
}

# Real-world files from testdata/, decoded with the package's own
# decoder and compared against Pillow. These are the files a user would
# actually decode, and they cover the sampling modes that the from-scratch
# encoder never produces (4:2:0 and friends).
FILE_FIXTURES = [
    ("jpeg_natural_64x64", "testdata/jpeg/jpeg_natural_64x64.jpg",
     "decode_jpeg"),
    ("jpeg_hq_64x64", "testdata/jpeg/jpeg_hq_64x64.jpg", "decode_jpeg"),
    ("jpeg_tiny_1x1", "testdata/jpeg/jpeg_tiny_1x1.jpg", "decode_jpeg"),
]

# The test images. Each is generated deterministically so that both
# implementations see exactly the same pixels.
def make_images():
    """Return a list of (name, width, height, rgba_bytes)."""
    out = []

    # A small gradient with a transparent corner.
    w, h = 16, 16
    px = bytearray()
    for y in range(h):
        for x in range(w):
            px += bytes([(x * 15) % 256, (y * 15) % 256, ((x + y) * 7) % 256,
                          0 if (x < 4 and y < 4) else 255])
    out.append(("gradient", w, h, bytes(px)))

    # A flat opaque colour: compresses well, exposes padding bugs.
    out.append(("flat", 8, 8, bytes([0x20, 0x40, 0x80, 0xFF] * 64)))

    # A single pixel.
    out.append(("one_pixel", 1, 1, bytes([1, 2, 3, 4])))

    # A row of pure black next to a row of pure white: a vertical edge.
    px = bytearray()
    for y in range(8):
        for x in range(8):
            v = 0 if y < 4 else 255
            px += bytes([v, v, v, 255])
    out.append(("edge", 8, 8, bytes(px)))

    # Pseudo-random noise: incompressible, so the encoders fall back to
    # literals and any bit-packing bug shows up immediately.
    px = bytearray()
    state = 12345
    for _ in range(16 * 16):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        px += bytes([(state >> 16) & 0xFF, (state >> 8) & 0xFF, state & 0xFF, 255])
    out.append(("noise", 16, 16, bytes(px)))

    # A set of sizes that stress the row filters and the compressor:
    # widths that are not a multiple of the 4 byte pixel size, heights
    # that are not a multiple of the 8 byte block size, and both.
    for w, h in [(12, 9), (13, 9), (12, 10), (12, 8), (9, 12), (17, 13),
                 (33, 17)]:
        px = bytearray()
        for y in range(h):
            for x in range(w):
                px += bytes([(x * 7 + y * 3) % 256, (x * 11 + y * 5) % 256,
                             (x * 13 + y * 17) % 256, (x * 19 + y * 23) % 256])
        out.append(("size_%dx%d" % (w, h), w, h, bytes(px)))
    return out


def hexify(data):
    return data.hex()


def build_project(workdir):
    """Create the throwaway project with both implementations available."""
    proj = os.path.join(workdir, "cmp")
    os.makedirs(proj, exist_ok=True)
    subprocess.run([MOON, "new", proj], check=True, capture_output=True)

    # local_image: a copy of the package under test.
    local = os.path.join(proj, "local_image")
    os.makedirs(local, exist_ok=True)
    for name in RUNTIME_SOURCES:
        src = os.path.join(ROOT, name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(local, name))
    with open(os.path.join(local, "moon.pkg"), "w", encoding="utf-8") as fh:
        fh.write("import {\n}\n\nsupported_targets = \"+native\"\n")

    # `PixelFormat` is a `pub enum`, so its variants cannot be constructed
    # from outside the package - "Cannot create values of the read-only
    # type". This three-line adapter is added to the COPY only, so that
    # the driver can build an input image.
    with open(os.path.join(local, "zz_crosscheck_adapter.mbt"), "w",
              encoding="utf-8") as fh:
        fh.write("// Added by the cross-check harness, not part of the package.\n")
        fh.write("pub fn crosscheck_make_rgba8("
                 "w : Int32, h : Int32, data : Bytes) -> Image {\n")
        fh.write("  Image::new(w, h, PixelFormat::RGBA8, data)\n")
        fh.write("}\n")
        # The colour channels of any decoded image, so that the harness
        # can compare the package's own decoder against Pillow.
        fh.write("\npub fn crosscheck_rgb_bytes(img : Image) -> Bytes {\n")
        fh.write("  let rgba = img.to_rgba8()\n")
        fh.write("  let count = img.width * img.height\n")
        fh.write("  let out = Array::make(count * 3, b'\\x00')\n")
        fh.write("  let mut i = 0\n")
        fh.write("  while i < count {\n")
        fh.write("    out[i * 3] = rgba.data[i * 4]\n")
        fh.write("    out[i * 3 + 1] = rgba.data[i * 4 + 1]\n")
        fh.write("    out[i * 3 + 2] = rgba.data[i * 4 + 2]\n")
        fh.write("    i = i + 1\n")
        fh.write("  }\n")
        fh.write("  Bytes::from_array(out)\n")
        fh.write("}\n")

    # The root package imports both implementations. The module name is
    # whatever `moon new` derived from the directory, so read it back.
    with open(os.path.join(proj, "moon.mod"), encoding="utf-8") as fh:
        module = None
        for line in fh:
            line = line.strip()
            if line.startswith("name"):
                module = line.split("=", 1)[1].strip().strip('"')
                break
    if not module:
        raise SystemExit("could not read the module name from moon.mod")
    with open(os.path.join(proj, "moon.pkg"), "w", encoding="utf-8") as fh:
        fh.write('import {\n  "mizchi/image",\n  "%s/local_image",\n}\n\n'
                 'supported_targets = "+native"\n' % module)

    # The driver runs as the executable package.
    cmd_pkg = os.path.join(proj, "cmd", "main")
    os.makedirs(cmd_pkg, exist_ok=True)
    with open(os.path.join(cmd_pkg, "moon.pkg"), "w", encoding="utf-8") as fh:
        fh.write('import {\n  "mizchi/image",\n  "%s/local_image",\n}\n\n'
                 'pkgtype(kind: "executable")\n\nsupported_targets = "+native"\n'
                 % module)

    # `moon new` picks wasm as the preferred target; this comparison is
    # native-only, because the wasm target needs a different SIMD build.
    mod_path = os.path.join(proj, "moon.mod")
    with open(mod_path, encoding="utf-8") as fh:
        mod_text = fh.read()
    mod_text = mod_text.replace('preferred_target = "wasm"',
                                'preferred_target = "native"')
    with open(mod_path, "w", encoding="utf-8") as fh:
        fh.write(mod_text)

    subprocess.run([MOON, "add", "mizchi/image@0.5.0"], cwd=proj,
                   check=True, capture_output=True)
    return proj


def write_driver(proj, images, formats, file_fixtures=None):
    """Generate the MoonBit driver that encodes with both implementations."""
    lines = []
    lines.append("// Generated by .tools/cross_check_encoders.py - do not edit.")
    lines.append("")
    for name, w, h, px in images:
        hexed = hexify(px)
        literal = "".join("\\x%s" % hexed[i:i + 2] for i in range(0, len(hexed), 2))
        lines.append('fn img_%s() -> Bytes {' % name)
        lines.append('  b"%s"' % literal)
        lines.append("}")
        lines.append("")

    # One function per (format, image): a failure must not stop the
    # other images from being encoded.
    for fmt, spec in formats.items():
        mine = spec["mine"]
        theirs = spec["theirs"]
        mine_args = spec.get("mine_args", "")
        theirs_args = spec.get("theirs_args", "")
        decoder = spec.get("decoder")
        for name, w, h, px in images:
            lines.append("fn enc_%s_%s() -> (String, String, String) {" % (fmt, name))
            lines.append("  let img = @local_image.crosscheck_make_rgba8("
                         "%d, %d, img_%s())" % (w, h, name))
            lines.append("  let mine = @local_image.%s(img%s) catch { "
                         "_ => return (\"\", \"\", \"\") }" % (mine, mine_args))
            # The package's own decoder, so that the harness can also
            # check the decoder against Pillow.
            self_hex = ""
            if decoder:
                lines.append("  let decoded = @local_image.%s(mine) catch { "
                             "_ => return (hex_of(mine), \"\", \"\") }" % decoder)
                lines.append("  let self_hex = hex_of("
                             "@local_image.crosscheck_rgb_bytes(decoded))")
            if theirs:
                lines.append("  let theirs = @image.%s("
                             "@image.ImageData::{ width: %d, height: %d, "
                             "data: img.data }%s) catch { _ => return "
                             "(hex_of(mine), \"\", self_hex) }" % (theirs, w, h, theirs_args))
                lines.append("  (hex_of(mine), hex_of(theirs), self_hex)")
            else:
                lines.append("  (hex_of(mine), \"\", self_hex)")
            lines.append("}")
            lines.append("")

    # Real-world files: decode them with the package's own decoder and
    # let the harness compare the result against Pillow.
    for name, path, decoder in (file_fixtures or []):
        with open(path, "rb") as fh:
            raw = fh.read()
        hexed = hexify(raw)
        literal = "".join("\\x%s" % hexed[i:i + 2]
                          for i in range(0, len(hexed), 2))
        lines.append("fn file_%s() -> Bytes {" % name)
        lines.append('  b"%s"' % literal)
        lines.append("}")
        lines.append("")
        lines.append("fn dec_%s() -> String {" % name)
        lines.append("  let img = @local_image.%s(file_%s()) catch { "
                     "_ => return \"\" }" % (decoder, name))
        lines.append("  hex_of(@local_image.crosscheck_rgb_bytes(img))")
        lines.append("}")
        lines.append("")

    lines.append("fn main {")
    for fmt, spec in formats.items():
        for name, w, h, px in images:
            lines.append("  {")
            lines.append("    let (m, t, s) = enc_%s_%s()" % (fmt, name))
            lines.append('    if m == "" { println("ERR %s %s mine") } '
                         'else { println("MINE %s %s " + m) }' % (fmt, name, fmt, name))
            lines.append('    if t == "" { println("ERR %s %s theirs") } '
                         'else { println("THEIRS %s %s " + t) }' % (fmt, name, fmt, name))
            lines.append('    if s == "" { println("ERR %s %s self") } '
                         'else { println("SELF %s %s " + s) }' % (fmt, name, fmt, name))
            lines.append("  }")
    for name, path, decoder in (file_fixtures or []):
        lines.append("  {")
        lines.append("    let s = dec_%s()" % name)
        lines.append('    if s == "" { println("ERR file_%s self") } '
                     'else { println("SELF file_%s " + s) }' % (name, name))
        lines.append("  }")
    lines.append("}")
    lines.append("")
    lines.append("fn hex_of(data : Bytes) -> String {")
    lines.append('  let digits = ["0", "1", "2", "3", "4", "5", "6", "7", '
                 '"8", "9", "a", "b", "c", "d", "e", "f"]')
    lines.append('  let mut out = ""')
    lines.append("  for i = 0; i < data.length(); i = i + 1 {")
    lines.append("    let b = data[i].to_int()")
    lines.append("    out = out + digits[b >> 4] + digits[b & 15]")
    lines.append("  }")
    lines.append("  out")
    lines.append("}")
    with open(os.path.join(proj, "cmd", "main", "main.mbt"), "w",
              encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def run_driver(proj):
    out = subprocess.run([MOON, "run", "--target", "native", "cmd/main"],
                         cwd=proj, capture_output=True, text=True,
                         encoding="utf-8", errors="replace", timeout=900)
    if out.returncode != 0:
        err_lines = out.stderr.splitlines()
        keep = []
        for i, l in enumerate(err_lines):
            if "Error" in l:
                keep.extend(err_lines[max(0, i - 2):i + 12])
        print("driver failed:")
        for l in (keep[:60] or err_lines[-25:]):
            print("  " + l)
        print("--- stdout tail ---")
        print(out.stdout[-2000:])
        raise SystemExit("driver failed")
    results = {}
    raw_dump = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "_build", "crosscheck_raw_stdout.txt")
    try:
        os.makedirs(os.path.dirname(raw_dump), exist_ok=True)
        with open(raw_dump, "w", encoding="utf-8") as fh:
            fh.write(out.stdout)
    except OSError:
        raw_dump = None
    for line in out.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "SELF" and len(parts) >= 3 and parts[1].startswith("file_"):
            # "SELF file_<name> <hex>"
            hexed = "".join(parts[2:])
            try:
                results[("SELF", parts[1], "")] = bytes.fromhex(hexed)
            except ValueError:
                print("  unparsable output (%d hex chars): %s..."
                      % (len(hexed), hexed[:80]))
            continue
        if len(parts) >= 4 and parts[0] in ("MINE", "THEIRS", "SELF"):
            hexed = "".join(parts[3:])
            try:
                results[(parts[0], parts[1], parts[2])] = bytes.fromhex(hexed)
            except ValueError:
                print("  unparsable output (%d hex chars): %s..."
                      % (len(hexed), hexed[:80]))
        elif parts[0] == "ERR":
            print("  driver error: %s" % line)
    if not results:
        print("--- raw driver stdout ---")
        print(out.stdout[-4000:])
        print("--- raw driver stderr ---")
        print(out.stderr[-2000:])
    return results


def compare_with_pillow(results, images, formats):
    """Decode both outputs with Pillow and compare the pixels.

    Pillow is a third, independent implementation, so this answers the
    question that actually matters: does the from-scratch encoder produce
    a file that the rest of the world reads back as the same image?

    For lossless formats the pixels must be identical. For lossy ones
    they may differ slightly, and the difference is reported.
    """
    try:
        from PIL import Image
    except ImportError:
        print("Pillow is not installed - skipping the pixel comparison")
        return 1

    import io
    by_name = {name: (w, h, px) for name, w, h, px in images}
    failures = 0
    checked = 0

    for fmt, spec in sorted(formats.items()):
        compare = spec.get("compare", "theirs")
        for name in sorted(by_name):
            mine = results.get(("MINE", fmt, name))
            theirs = results.get(("THEIRS", fmt, name))
            self_px = results.get(("SELF", fmt, name))
            if mine is None:
                print("  %-5s %-12s NO OUTPUT FROM OUR ENCODER" % (fmt, name))
                failures += 1
                continue
            try:
                a = Image.open(io.BytesIO(mine))
                a.load()
            except Exception as exc:
                print("  %-5s %-12s Pillow cannot read our output: %s"
                      % (fmt, name, exc))
                failures += 1
                continue

            w, h, px = by_name[name]
            src = Image.frombytes("RGBA", (w, h), px)

            # The package's own decoder must agree with Pillow about
            # what our encoder wrote. This is the check that catches a
            # decoder bug that only our own encoder can expose.
            if self_px is not None:
                ref = a.convert("RGB")
                mine_px = list(ref.get_flattened_data())
                self_diff = _raw_diff(mine_px, self_px)
                # A lossless format has to match exactly. A lossy one
                # cannot: the package's IDCT is a fixed-point
                # approximation of libjpeg's integer one, so the two
                # differ by a unit or two on every pixel.
                limit = spec.get("decoder_limit", 0)
                if self_diff["max"] > limit:
                    print("  %-5s %-12s OUR OWN DECODER DISAGREES WITH PILLOW "
                          "max=%d changed=%d/%d"
                          % (fmt, name, self_diff["max"],
                             self_diff["changed"], self_diff["total"]))
                    failures += 1
                else:
                    print("  %-5s %-12s decoder ok  our decoder matches Pillow "
                          "(max=%d)" % (fmt, name, self_diff["max"]))

            ours = a.convert("RGBA")
            if ours.size != src.size:
                print("  %-5s %-12s SIZE MISMATCH ours=%s source=%s"
                      % (fmt, name, ours.size, src.size))
                failures += 1
                continue

            theirs_img = None
            if theirs is not None:
                try:
                    b = Image.open(io.BytesIO(theirs))
                    b.load()
                    theirs_img = b.convert("RGBA")
                except Exception as exc:
                    print("  %-5s %-12s Pillow cannot read the reference output: %s"
                          % (fmt, name, exc))
                    failures += 1
                    continue

            if compare == "theirs":
                if theirs_img is None:
                    # No reference encoder for this format; check our
                    # output against the source image only. Formats that
                    # can only carry binary transparency (GIF) declare a
                    # threshold: a source pixel below it is expected to
                    # come back fully transparent, not with its original
                    # alpha.
                    mismatch = _source_mismatch(ours, src,
                                                spec.get("alpha_below"))
                    if mismatch:
                        print("  %-5s %-12s our output does not match the "
                              "source (%s)" % (fmt, name, mismatch))
                        failures += 1
                    else:
                        print("  %-5s %-12s ok (no reference encoder; "
                              "matches source exactly)" % (fmt, name))
                    checked += 1
                    continue
                if ours.size != theirs_img.size:
                    print("  %-5s %-12s SIZE MISMATCH ours=%s theirs=%s"
                          % (fmt, name, ours.size, theirs_img.size))
                    failures += 1
                    continue
                diff = _pixel_diff(ours, theirs_img)
                if diff["max"] != 0:
                    print("  %-5s %-12s PIXEL MISMATCH max=%d changed=%d/%d"
                          % (fmt, name, diff["max"], diff["changed"],
                             diff["total"]))
                    failures += 1
                else:
                    print("  %-5s %-12s ok  pixels identical  (%d bytes ours / "
                          "%d theirs)" % (fmt, name, len(mine), len(theirs)))
            elif compare == "source":
                # A lossy format is only useful if it still shows the
                # source image: comparing it against another encoder
                # alone would hide a systematic error that both make.
                # JPEG carries no alpha channel, so only the colour
                # channels are compared against the source.
                channels = 3 if spec.get("no_alpha") else 4
                diff = _pixel_diff(ours, theirs_img)
                ours_vs_src = _pixel_diff(ours, src, channels)
                theirs_vs_src = _pixel_diff(theirs_img, src, channels)
                if ours_vs_src["max"] > 64:
                    print("  %-5s %-12s DOES NOT SHOW THE SOURCE max=%d "
                          "mean=%.2f" % (fmt, name, ours_vs_src["max"],
                                         ours_vs_src["mean"]))
                    failures += 1
                elif (ours_vs_src["max"] > theirs_vs_src["max"] + 8
                      or ours_vs_src["mean"] > theirs_vs_src["mean"] + 2.0):
                    # Two encoders of the same format never agree bit for
                    # bit, but ours must not be measurably worse than the
                    # reference: that is what a real bug looks like.
                    print("  %-5s %-12s WORSE THAN THE REFERENCE: ours vs "
                          "source max=%d mean=%.2f, theirs vs source "
                          "max=%d mean=%.2f"
                          % (fmt, name, ours_vs_src["max"],
                             ours_vs_src["mean"], theirs_vs_src["max"],
                             theirs_vs_src["mean"]))
                    failures += 1
                else:
                    print("  %-5s %-12s ok  ours vs theirs max=%d mean=%.2f; "
                          "ours vs source max=%d mean=%.2f; theirs vs source "
                          "max=%d mean=%.2f (%d bytes ours / %d theirs)"
                          % (fmt, name, diff["max"], diff["mean"],
                             ours_vs_src["max"], ours_vs_src["mean"],
                             theirs_vs_src["max"], theirs_vs_src["mean"],
                             len(mine), len(theirs)))
            elif compare == "gif":
                # GIF carries binary transparency only, and its palette
                # holds at most 256 colours: an image with more colours
                # has to be quantised, and an image with a partial alpha
                # has to be flattened to transparent or opaque. Both are
                # compared against the source with that in mind.
                thr = spec.get("alpha_below", 128)
                ours_diff = _gif_diff(ours, src, thr)
                if theirs_img is not None:
                    ref_diff = _gif_diff(theirs_img, src, thr)
                    ref_name = "the reference encoder"
                else:
                    # The reference encoder refused the image (it only
                    # accepts binary alpha and at most 256 colours), so
                    # Pillow's own GIF encoder is the reference.
                    ref_diff = _gif_diff(_pillow_gif_reference(src, thr),
                                         src, thr)
                    ref_name = "Pillow's encoder"
                if ours_diff["transparent_errors"] > 0:
                    print("  %-5s %-12s TRANSPARENCY IS WRONG: %d pixels that "
                          "should be transparent are not"
                          % (fmt, name, ours_diff["transparent_errors"]))
                    failures += 1
                elif (ours_diff["mean"] > ref_diff["mean"] + 2.0
                      or ours_diff["max"] > ref_diff["max"] + 32):
                    print("  %-5s %-12s WORSE THAN %s: ours vs source "
                          "max=%d mean=%.2f, reference vs source max=%d "
                          "mean=%.2f"
                          % (fmt, name, ref_name, ours_diff["max"],
                             ours_diff["mean"], ref_diff["max"],
                             ref_diff["mean"]))
                    failures += 1
                else:
                    print("  %-5s %-12s ok  ours vs source max=%d mean=%.2f; "
                          "%s vs source max=%d mean=%.2f (%d bytes ours / %d "
                          "reference)"
                          % (fmt, name, ours_diff["max"], ours_diff["mean"],
                             ref_name, ref_diff["max"], ref_diff["mean"],
                             len(mine),
                             len(theirs) if theirs is not None else 0))
            checked += 1

    print("compared %d image/format pairs, %d failures" % (checked, failures))
    return failures


def _pixels(im):
    """The pixels of an image as a flat list of RGBA tuples."""
    try:
        return list(im.convert("RGBA").get_flattened_data())
    except AttributeError:
        return list(im.convert("RGBA").getdata())


def _source_mismatch(decoded, source, alpha_threshold):
    """Compare a decoded image with the source image.

    `alpha_threshold` is None for formats that preserve alpha exactly.
    When it is set, a source pixel whose alpha is below the threshold is
    expected to decode to a fully transparent pixel, because the format
    only carries binary transparency.
    """
    got = _pixels(decoded)
    want = _pixels(source)
    if len(got) != len(want):
        return "different pixel count (%d vs %d)" % (len(got), len(want))
    for i in range(len(want)):
        g = got[i]
        w = want[i]
        if alpha_threshold is not None and w[3] < alpha_threshold:
            if g[3] != 0:
                return "pixel %d should be transparent, got alpha %d" % (i, g[3])
            continue
        if tuple(g) != tuple(w):
            return "pixel %d differs: got %s want %s" % (i, tuple(g), tuple(w))
    return None


def _gif_diff(decoded, source, alpha_threshold):
    """Difference between a GIF decode and the source image.

    GIF carries binary transparency only, and at most 256 colours, so
    the comparison has to model both:

      - a source pixel whose alpha is below the threshold has to come
        back fully transparent,
      - every other source pixel has to come back opaque, with its
        colour quantised to the palette.
    """
    got = _pixels(decoded)
    want = _pixels(source)
    if len(got) != len(want):
        return {"max": 255, "mean": 255.0, "changed": len(want),
                "total": max(len(want), 1), "transparent_errors": len(want)}
    maxdiff = 0
    acc = 0
    changed = 0
    transparent_errors = 0
    total = 0
    for i in range(len(want)):
        g = got[i]
        w = want[i]
        if w[3] < alpha_threshold:
            if g[3] != 0:
                transparent_errors += 1
            continue
        total += 1
        d = 0
        for c in range(3):
            v = abs(g[c] - w[c])
            if v > d:
                d = v
        if g[3] != 255:
            # An opaque source pixel must not come back transparent.
            d = max(d, 255)
        if d:
            changed += 1
            acc += d
        if d > maxdiff:
            maxdiff = d
    return {"max": maxdiff, "mean": (acc / total) if total else 0.0,
            "changed": changed, "total": total,
            "transparent_errors": transparent_errors}


def _pillow_gif_reference(source, alpha_threshold):
    """A GIF written by Pillow's own encoder, used as the reference.

    The reference encoder of the comparison (mizchi/image) refuses
    images with a partial alpha or with more than 256 colours, so for
    those images Pillow's encoder is the reference instead.
    """
    import io
    from PIL import Image
    data = bytearray()
    for r, g, b, a in _pixels(source):
        if a < alpha_threshold:
            data += bytes((0, 0, 0))
        else:
            data += bytes((r, g, b))
    flat = Image.frombytes("RGB", source.size, bytes(data))
    quantised = flat.quantize(colors=255, method=Image.MEDIANCUT)
    buf = io.BytesIO()
    quantised.save(buf, format="GIF")
    buf.seek(0)
    out = Image.open(buf)
    out.load()
    return out


def _luma(pixels):
    """The luma of a flat pixel list, as 0..255 integers."""
    return [int(round(0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]))
            for p in pixels]


def _chroma(pixels):
    """The Cb and Cr of a flat pixel list."""
    out = []
    for r, g, b in pixels:
        out.append((int(round(-0.168736 * r - 0.331264 * g + 0.5 * b + 128)),
                    int(round(0.5 * r - 0.418688 * g - 0.081312 * b + 128))))
    return out


def _raw_diff(pixels, raw):
    """Difference between a flat pixel list and a flat RGB byte string."""
    total = min(len(pixels), len(raw) // 3)
    maxdiff = 0
    changed = 0
    acc = 0
    for i in range(total):
        d = 0
        for c in range(3):
            v = abs(pixels[i][c] - raw[i * 3 + c])
            if v > d:
                d = v
        if d:
            changed += 1
            acc += d
        if d > maxdiff:
            maxdiff = d
    return {"max": maxdiff, "mean": (acc / total) if total else 0.0,
            "changed": changed, "total": total}


def _pixel_diff(a, b, channels=4):
    """Per-channel difference statistics between two same-size images.

    `channels` limits how many channels are compared: 3 compares the
    colour channels only, which is what a format without an alpha
    channel (JPEG) needs.
    """
    pa = _pixels(a)
    pb = _pixels(b)
    total = len(pa)
    maxdiff = 0
    acc = 0
    changed = 0
    for i in range(total):
        d = 0
        for c in range(channels):
            v = abs(pa[i][c] - pb[i][c])
            if v > d:
                d = v
        if d:
            changed += 1
            acc += d
        if d > maxdiff:
            maxdiff = d
    return {
        "max": maxdiff,
        "mean": (acc / total) if total else 0.0,
        "changed": changed,
        "total": total,
    }


def compare_file_fixtures(results, file_fixtures):
    """Compare the package's own decoder against Pillow on real files.

    These files use the sampling modes that the from-scratch encoder
    never produces, so they cover the decoder on its own.
    """
    try:
        from PIL import Image
    except ImportError:
        print("Pillow is not installed - skipping the file comparison")
        return 0

    import io
    failures = 0
    for name, path, decoder in file_fixtures:
        raw = open(path, "rb").read()
        got = results.get(("SELF", "file_" + name, ""))
        if got is None:
            print("  file %-24s NO OUTPUT FROM OUR DECODER" % name)
            failures += 1
            continue
        try:
            ref = Image.open(io.BytesIO(raw))
            ref.load()
        except Exception as exc:
            print("  file %-24s Pillow cannot read it: %s" % (name, exc))
            failures += 1
            continue
        pixels = list(ref.convert("RGB").get_flattened_data())
        ours = [(got[i * 3], got[i * 3 + 1], got[i * 3 + 2])
                for i in range(len(got) // 3)]
        # The luma is not affected by the chroma upsampling, so it is
        # the part that has to agree with libjpeg. The chroma is
        # expected to differ: the package upsamples nearest-neighbour,
        # libjpeg uses a triangular filter.
        luma = _luma(pixels)
        ours_luma = _luma(ours)
        luma_diff = max((abs(a - b) for a, b in zip(luma, ours_luma)),
                        default=0)
        chroma = _chroma(pixels)
        ours_chroma = _chroma(ours)
        chroma_diff = max((max(abs(a[0] - b[0]), abs(a[1] - b[1]))
                           for a, b in zip(chroma, ours_chroma)), default=0)
        # The package's IDCT is a fixed-point approximation of
        # libjpeg's integer one, so the two never agree bit for bit.
        limit = 8
        if luma_diff > limit:
            print("  file %-24s OUR DECODER DISAGREES WITH PILLOW: luma "
                  "max=%d" % (name, luma_diff))
            failures += 1
        else:
            print("  file %-24s decoder ok  luma max=%d (chroma max=%d, the "
                  "upsampling filter differs)" % (name, luma_diff, chroma_diff))
    return failures


def dump_outputs(results, formats):
    """Write every encoded file to _build/crosscheck_out for inspection."""
    outdir = os.path.join(ROOT, "_build", "crosscheck_out")
    try:
        os.makedirs(outdir, exist_ok=True)
    except OSError:
        return None
    ext = {"png": "png", "gif": "gif", "jpeg": "jpg", "tga": "tga",
           "tga_rle": "tga", "ico": "ico", "tiff": "tiff"}
    for (who, fmt, name), data in sorted(results.items()):
        path = os.path.join(outdir, "%s_%s_%s.%s" % (who.lower(), fmt, name,
                                                     ext.get(fmt, "bin")))
        try:
            with open(path, "wb") as fh:
                fh.write(data)
        except OSError:
            return None
    return outdir


def main():
    which = sys.argv[1:] or list(FORMATS)
    formats = {k: v for k, v in FORMATS.items() if k in which}
    if not formats:
        raise SystemExit("no known format in %r" % (which,))

    images = make_images()
    workdir = tempfile.mkdtemp(prefix="xcheck_")
    try:
        proj = build_project(workdir)
        write_driver(proj, images, formats, FILE_FIXTURES)
        results = run_driver(proj)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print("encoded %d images x %d formats" % (len(images), len(formats)))
    for (who, fmt, name), data in sorted(results.items()):
        print("  %-7s %-5s %-12s %6d bytes" % (who, fmt, name, len(data)))
    print()

    outdir = dump_outputs(results, formats)
    if outdir:
        print("encoded files written to %s" % outdir)
        print()

    failures = compare_with_pillow(results, images, formats)
    print()
    failures += compare_file_fixtures(results, FILE_FIXTURES)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
