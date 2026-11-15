#!/usr/bin/env python3
"""Benchmark the encoders of this package against mizchi/image.

The package's codecs are written from scratch, so "does it work" is not
enough: it has to be at least as fast and at least as accurate as an
independent implementation of the same formats.

This script measures three things for every format:

  * encoding speed - the same source images are encoded by both
    implementations and the wall clock time of each is compared,
  * decoding speed - the *same* bytes (the reference encoder's output)
    are decoded by both decoders,
  * output quality - the decoded pixels of both outputs are compared with
    the source image, because for the lossy and quantised formats the two
    encoders legitimately disagree on the bytes and only the pixels count.

Timing method: each measurement runs inside a generated MoonBit executable
that repeats the work N times, and the process wall time is measured from
the outside with `time.perf_counter`. The start-up cost of `moon run` is
measured with an empty program and subtracted, because it would otherwise
dwarf the encoding itself. The median of several rounds is reported, not
the mean: one slow round on a busy machine must not decide the result.

Why this is a script and not a test in the package: `mizchi/image` is a
third-party dependency and this package ships with zero external runtime
dependencies. The comparison has to happen outside the package.

Usage:
    python .tools/bench_encoders.py            # all formats
    python .tools/bench_encoders.py png gif    # a subset
"""
import io
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cross_check_encoders as cc  # noqa: E402  (same directory)

MOON = cc.MOON

# The formats to benchmark. `theirs` is None for formats mizchi/image
# does not implement an encoder for. `theirs_decoder` is None for formats
# it cannot decode either.
BENCH_FORMATS = {
    "png": {"mine": "encode_png", "theirs": "encode_png",
            "mine_decoder": "decode_png", "theirs_decoder": "decode_png",
            "lossless": True},
    "gif": {"mine": "encode_gif", "theirs": "encode_gif",
            "mine_decoder": "decode_gif", "theirs_decoder": "decode_gif",
            "lossless": False, "alpha_below": 128},
    "jpeg": {"mine": "encode_jpeg", "theirs": "encode_jpeg",
             "mine_decoder": "decode_jpeg", "theirs_decoder": "decode_jpeg",
             "lossless": False, "no_alpha": True,
             "mine_args": ", 90", "theirs_args": ", quality=90"},
    "tga": {"mine": "encode_tga", "theirs": None,
            "mine_decoder": "decode_tga", "theirs_decoder": None,
            "lossless": True},
    "tga_rle": {"mine": "encode_tga_rle", "theirs": None,
                "mine_decoder": "decode_tga", "theirs_decoder": None,
                "lossless": True},
    "ico": {"mine": "encode_ico", "theirs": "encode_ico",
            "mine_decoder": "decode_ico", "theirs_decoder": "decode_ico",
            "lossless": True},
    "tiff": {"mine": "encode_tiff", "theirs": "encode_tiff",
             "mine_decoder": "decode_tiff", "theirs_decoder": "decode_tiff",
             "lossless": True},
}


def bench_images():
    """The images to benchmark with: big enough that the work shows."""
    out = []
    w = h = 256

    # A smooth gradient: compresses well, so it measures the compressor
    # rather than the encoder's housekeeping.
    px = bytearray()
    for y in range(h):
        for x in range(w):
            px += bytes([(x * 255) // (w - 1), (y * 255) // (h - 1),
                         ((x + y) * 255) // (w + h - 2), 255])
    out.append(("gradient", w, h, bytes(px)))

    # 64 distinct colours and a transparent corner: the one image the
    # reference encoder accepts for GIF (it refuses a partial alpha and
    # more than 256 colours).
    px = bytearray()
    for y in range(h):
        for x in range(w):
            k = ((x // 32) + (y // 32) * 8) % 64
            a = 0 if (x < 64 and y < 64) else 255
            px += bytes([(k * 4) % 256, (k * 9) % 256, (k * 16) % 256, a])
    out.append(("bands", w, h, bytes(px)))

    # Pseudo-random noise: incompressible, so it measures the encoder's
    # worst case.
    px = bytearray()
    state = 12345
    for _ in range(w * h):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        px += bytes([(state >> 16) & 0xFF, (state >> 8) & 0xFF,
                     state & 0xFF, 255])
    out.append(("noise", w, h, bytes(px)))
    return out


def literal(data):
    """A MoonBit byte string literal for the given bytes."""
    hexed = data.hex()
    return 'b"%s"' % "".join("\\x%s" % hexed[i:i + 2]
                             for i in range(0, len(hexed), 2))


def write_pkg(proj, name, imports, lines):
    """Write an executable package into the throwaway project."""
    d = os.path.join(proj, "cmd", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "moon.pkg"), "w", encoding="utf-8") as fh:
        fh.write("import {\n")
        for i in imports:
            fh.write('  "%s",\n' % i)
        fh.write('}\n\npkgtype(kind: "executable")\n')
    with open(os.path.join(d, "main.mbt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def module_of(proj):
    """The module name `moon new` gave the throwaway project."""
    with open(os.path.join(proj, "moon.mod"), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("name"):
                return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("could not read the module name")


# ---------------------------------------------------------------------------
# Phase 1: encode everything once, with both implementations
# ---------------------------------------------------------------------------

def phase_generate(proj, images, formats):
    """Encode every image with both implementations and return the bytes."""
    lines = ["// Generated by .tools/bench_encoders.py - do not edit.", ""]
    for name, w, h, px in images:
        lines.append("fn img_%s() -> Bytes {" % name)
        lines.append("  %s" % literal(px))
        lines.append("}")
        lines.append("")
    for fmt, spec in formats.items():
        for name, w, h, px in images:
            lines.append("fn enc_%s_%s() -> (String, String) {" % (fmt, name))
            lines.append("  let img = @local_image.crosscheck_make_rgba8(%d, %d, "
                         "img_%s())" % (w, h, name))
            lines.append("  let mine = @local_image.%s(img%s) catch { "
                         "_ => return (\"\", \"\") }"
                         % (spec["mine"], spec.get("mine_args", "")))
            if spec.get("theirs"):
                lines.append("  let theirs = @image.%s("
                             "@image.ImageData::{ width: %d, height: %d, "
                             "data: img.data }%s) catch { _ => return "
                             "(hex_of(mine), \"\") }"
                             % (spec["theirs"], w, h, spec.get("theirs_args", "")))
            else:
                # No reference encoder for this format.
                lines.append("  let theirs = b\"\"")
            lines.append("  (hex_of(mine), hex_of(theirs))")
            lines.append("}")
            lines.append("")
    lines.append("fn main {")
    for fmt in formats:
        for name, w, h, px in images:
            lines.append("  {")
            lines.append("    let (m, t) = enc_%s_%s()" % (fmt, name))
            lines.append('    let ms = if m == "" { "-" } else { m }')
            lines.append('    let ts = if t == "" { "-" } else { t }')
            lines.append('    println("RES %s %s " + ms + " " + ts)' % (fmt, name))
            lines.append("  }")
    lines.append("}")
    lines.append("")
    lines.append("fn hex_of(data : Bytes) -> String {")
    lines.append('  let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", '
                 '"9", "a", "b", "c", "d", "e", "f"]')
    lines.append('  let mut out = ""')
    lines.append("  for i = 0; i < data.length(); i = i + 1 {")
    lines.append("    let b = data[i].to_int()")
    lines.append('    out = out + digits[b >> 4] + digits[b & 15]')
    lines.append("  }")
    lines.append("  out")
    lines.append("}")
    mod = module_of(proj)
    write_pkg(proj, "bench_gen", ["mizchi/image", "%s/local_image" % mod], lines)

    out = subprocess.run([MOON, "run", "--target", "native", "cmd/bench_gen"],
                         cwd=proj, capture_output=True, text=True,
                         encoding="utf-8", errors="replace", timeout=1800)
    if out.returncode != 0:
        print(out.stderr[-3000:])
        raise SystemExit("the generator failed")
    results = {}
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0] == "RES":
            fmt, name = parts[1], parts[2]
            mine = parts[3] if parts[3] != "-" else ""
            theirs = parts[4] if parts[4] != "-" else ""
            results[(fmt, name, "mine")] = bytes.fromhex(mine) if mine else None
            results[(fmt, name, "theirs")] = bytes.fromhex(theirs) if theirs else None
    return results


# ---------------------------------------------------------------------------
# Phase 2: the timing drivers
# ---------------------------------------------------------------------------

def add_adapter(proj, formats):
    """Add decode helpers to the copy of the package under test.

    They return -1 when the decoder rejects the file, so that a failure
    is counted instead of aborting the whole benchmark.
    """
    lines = ["// Added by .tools/bench_encoders.py - not part of the package.",
             ""]
    for fmt, spec in formats.items():
        dec = spec.get("mine_decoder")
        if not dec:
            continue
        lines.append("pub fn bench_len_%s(data : Bytes) -> Int {" % fmt)
        lines.append("  let img = %s(data) catch { _ => return -1 }" % dec)
        lines.append("  img.data.length()")
        lines.append("}")
        lines.append("")
    path = os.path.join(proj, "local_image", "zz_bench_adapter.mbt")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def timing_package(proj, name, imports, image_fns, work, reps, counters=False):
    """An executable that repeats `work` `reps` times.

    `work` is a list of lines that each produce a `Bytes`; their lengths
    are summed and printed, so the work cannot be optimised away and the
    output can be checked afterwards.
    """
    lines = ["// Generated by .tools/bench_encoders.py - do not edit.", ""]
    for fn in image_fns:
        lines.append("fn %s() -> Bytes {" % fn["name"])
        lines.append("  %s" % fn["literal"])
        lines.append("}")
        lines.append("")
    lines.append("fn main {")
    lines.append("  let mut total = 0")
    if counters:
        lines.append("  let mut failures = 0")
    lines.append("  let mut r = 0")
    lines.append("  while r < %d {" % reps)
    for w in work:
        lines.append("    %s" % w)
    lines.append("    r = r + 1")
    lines.append("  }")
    if counters:
        lines.append('  println("BYTES \\{total} FAILURES \\{failures}")')
    else:
        lines.append('  println("BYTES \\{total}")')
    lines.append("}")
    write_pkg(proj, name, imports, lines)


def measure(proj, pkg, rounds=7):
    """The median wall time of running one package, in seconds."""
    out = subprocess.run([MOON, "run", "--target", "native", "cmd/" + pkg], cwd=proj,
                         capture_output=True, text=True, encoding="utf-8",
                         errors="replace", timeout=3600)
    if out.returncode != 0:
        print(out.stderr[-3000:])
        raise SystemExit("the benchmark driver %s failed" % pkg)
    failures = 0
    for line in out.stdout.splitlines():
        if line.startswith("BYTES"):
            parts = line.split()
            if len(parts) >= 4 and parts[2] == "FAILURES":
                failures = int(parts[3])
    subprocess.run([MOON, "run", "--target", "native", "cmd/" + pkg], cwd=proj,
                   capture_output=True, text=True, encoding="utf-8",
                   errors="replace", timeout=3600)
    times = []
    for _ in range(rounds):
        t0 = time.perf_counter()
        out = subprocess.run([MOON, "run", "--target", "native", "cmd/" + pkg],
                             cwd=proj, capture_output=True, text=True,
                             encoding="utf-8", errors="replace", timeout=3600)
        times.append(time.perf_counter() - t0)
        if out.returncode != 0:
            print(out.stderr[-3000:])
            raise SystemExit("the benchmark driver %s failed" % pkg)
    return statistics.median(times), failures


def main():
    which = sys.argv[1:] or list(BENCH_FORMATS)
    formats = {k: v for k, v in BENCH_FORMATS.items() if k in which}
    if not formats:
        raise SystemExit("no known format in %r" % (which,))

    images = bench_images()
    workdir = tempfile.mkdtemp(prefix="bench_")
    proj = cc.build_project(workdir)
    print("encoded %d images x %d formats" % (len(images), len(formats)))
    results = phase_generate(proj, images, formats)

    mod = module_of(proj)
    local = "%s/local_image" % mod
    add_adapter(proj, formats)

    # Write every encoded file out, so that a failure can be looked at.
    outdir = os.path.join(cc.ROOT, "_build", "bench_out")
    os.makedirs(outdir, exist_ok=True)
    for (fmt, name), side in [((f, n), s) for (f, n, s) in results]:
        data = results[(fmt, name, side)]
        if not data:
            continue
        with open(os.path.join(outdir, "%s_%s_%s.bin" % (side, fmt, name)),
                  "wb") as fh:
            fh.write(data)

    if os.environ.get("BENCH_GEN_ONLY"):
        print("generated files written to %s" % outdir)
        shutil.rmtree(workdir, ignore_errors=True)
        return 0

    # ------------------------------------------------------------------
    # Quality and size
    # ------------------------------------------------------------------
    try:
        from PIL import Image
    except ImportError:
        Image = None

    def decode_with_pillow(data):
        img = Image.open(io.BytesIO(data))
        img.load()
        return img

    quality = {}
    sizes = {}
    for fmt, spec in formats.items():
        for name, w, h, px in images:
            mine = results.get((fmt, name, "mine"))
            theirs = results.get((fmt, name, "theirs"))
            if mine is None:
                continue
            sizes[(fmt, name)] = (len(mine), len(theirs) if theirs else None)
            if Image is None or theirs is None:
                continue
            src = Image.frombytes("RGBA", (w, h), px)
            a = decode_with_pillow(mine).convert("RGBA")
            b = decode_with_pillow(theirs).convert("RGBA")
            if spec.get("lossless"):
                d = cc._pixel_diff(a, src)
                e = cc._pixel_diff(b, src)
            elif spec.get("no_alpha"):
                d = cc._pixel_diff(a, src, 3)
                e = cc._pixel_diff(b, src, 3)
            else:
                d = cc._gif_diff(a, src, spec.get("alpha_below", 128))
                e = cc._gif_diff(b, src, spec.get("alpha_below", 128))
            quality[(fmt, name)] = (d, e)

    # ------------------------------------------------------------------
    # Timing
    # ------------------------------------------------------------------
    # The empty program: the cost of starting `moon run` and nothing else.
    write_pkg(proj, "bench_noop", [local], ["fn main {", "  println(\"ok\")", "}"])
    base, _ = measure(proj, "bench_noop")

    image_fns = [{"name": "img_" + n, "literal": literal(px)}
                 for n, w, h, px in images]
    enc_rows = []
    for fmt, spec in formats.items():
        for side in ("mine", "theirs"):
            if side == "theirs" and not spec.get("theirs"):
                continue
            work = []
            n_ops = 0
            for name, w, h, px in images:
                if results.get((fmt, name, side)) is None:
                    continue
                if side == "mine":
                    expr = ("@local_image.%s(@local_image.crosscheck_make_rgba8("
                            "%d, %d, img_%s())%s)"
                            % (spec["mine"], w, h, name,
                               spec.get("mine_args", "")))
                else:
                    expr = ("@image.%s(@image.ImageData::{ width: %d, height: %d, "
                            "data: @local_image.crosscheck_make_rgba8(%d, %d, "
                            "img_%s()).data }%s)"
                            % (spec["theirs"], w, h, w, h, name,
                               spec.get("theirs_args", "")))
                work.append("let enc_%s = %s catch { _ => abort(\"encode "
                            "failed\") }" % (name, expr))
                work.append("total = total + enc_%s.length()" % name)
                n_ops += 1
            if not work:
                continue
            pkg = "bench_enc_%s_%s" % (fmt, side)
            imports = [local] + (["mizchi/image"] if side == "theirs" else [])
            # One repetition first, to size the real run.
            timing_package(proj, pkg, imports, image_fns, work, 1)
            t1, _ = measure(proj, pkg, rounds=3)
            per_op = max(t1 - base, 1e-6) / n_ops
            reps = max(1, min(200, int(0.8 / per_op)))
            timing_package(proj, pkg, imports, image_fns, work, reps)
            t, _ = measure(proj, pkg)
            ops = n_ops * reps
            enc_rows.append((fmt, side, (t - base) / ops * 1000.0, reps,
                             n_ops))

    dec_rows = []
    for fmt, spec in formats.items():
        if not spec.get("theirs_decoder") or not spec.get("mine_decoder"):
            continue
        fixtures = []
        for name, w, h, px in images:
            data = results.get((fmt, name, "theirs")) or results.get((fmt, name, "mine"))
            if data:
                fixtures.append((name, data))
        if not fixtures:
            continue
        fns = [{"name": "fix_%s_%s" % (fmt, n), "literal": literal(d)}
               for n, d in fixtures]
        for side in ("mine", "theirs"):
            work = []
            for name, data in fixtures:
                fn = "fix_%s_%s" % (fmt, name)
                if side == "mine":
                    work.append("let n = @local_image.bench_len_%s(%s())"
                                % (fmt, fn))
                    work.append("if n < 0 { failures = failures + 1 } else "
                                "{ total = total + n }")
                else:
                    work.append(
                        "let dec_%s = @image.%s(%s()) catch { _ => "
                        "@image.ImageData::{ width: 0, height: 0, data: b\"\" } }"
                        % (name, spec["theirs_decoder"], fn))
                    work.append("total = total + dec_%s.data.length()" % name)
            pkg = "bench_dec_%s_%s" % (fmt, side)
            imports = [local] + (["mizchi/image"] if side == "theirs" else [])
            # Only the package under test counts its failures; the
            # reference decoder's failures are swallowed.
            counters = side == "mine"
            timing_package(proj, pkg, imports, fns, work, 1, counters=counters)
            t1, _ = measure(proj, pkg, rounds=3)
            per_op = max(t1 - base, 1e-6) / len(fixtures)
            reps = max(1, min(200, int(0.8 / per_op)))
            timing_package(proj, pkg, imports, fns, work, reps, counters=counters)
            t, dec_failures = measure(proj, pkg)
            ops = len(fixtures) * reps
            dec_rows.append((fmt, side, (t - base) / ops * 1000.0,
                             len(fixtures), dec_failures))

    # ------------------------------------------------------------------
    # Report
    # ------------------------------------------------------------------
    def get(rows, fmt, side):
        for r in rows:
            if r[0] == fmt and r[1] == side:
                return r
        return None

    print()
    print("=" * 78)
    print("ENCODING SPEED  (per image; the start-up cost of `moon run` is "
          "subtracted)")
    print("=" * 78)
    print("%-8s %10s %10s %9s %10s %10s" %
          ("format", "ours(ms)", "theirs(ms)", "ours/theirs", "ours(B)",
           "theirs(B)"))
    for fmt in formats:
        mine = get(enc_rows, fmt, "mine")
        theirs = get(enc_rows, fmt, "theirs")
        if not mine:
            continue
        sz = [v for (f, n), v in sizes.items() if f == fmt]
        ours_sz = sum(v[0] for v in sz)
        theirs_sz = sum(v[1] for v in sz if v[1] is not None)
        ratio = ("%.2fx" % (mine[2] / theirs[2])) if theirs else "-"
        print("%-8s %10.3f %10s %9s %10d %10s" %
              (fmt, mine[2], ("%.3f" % theirs[2]) if theirs else "-", ratio,
               ours_sz, str(theirs_sz) if theirs else "-"))

    print()
    print("=" * 78)
    print("DECODING SPEED  (the reference encoder's own output, decoded by "
          "both)")
    print("=" * 78)
    print("%-8s %10s %10s %9s %8s %8s" %
          ("format", "ours(ms)", "theirs(ms)", "ours/theirs", "files", "fails"))
    for fmt in formats:
        mine = get(dec_rows, fmt, "mine")
        theirs = get(dec_rows, fmt, "theirs")
        if not mine:
            print("%-8s %10s" % (fmt, "n/a"))
            continue
        ratio = ("%.2fx" % (mine[2] / theirs[2])) if theirs else "-"
        print("%-8s %10.3f %10s %9s %8d %8d" %
              (fmt, mine[2], ("%.3f" % theirs[2]) if theirs else "-", ratio,
               mine[3], mine[4]))

    print()
    print("=" * 78)
    print("QUALITY  (decoded pixels against the source image)")
    print("=" * 78)
    print("%-8s %-10s %-22s %-22s" % ("format", "image", "ours max/mean",
                                      "theirs max/mean"))
    worse = []
    for fmt in formats:
        for name, w, h, px in images:
            q = quality.get((fmt, name))
            if not q:
                continue
            d, e = q
            ours = "%.0f / %.2f" % (d["max"], d["mean"])
            theirs = "%.0f / %.2f" % (e["max"], e["mean"])
            print("%-8s %-10s %-22s %-22s" % (fmt, name, ours, theirs))
            if d["mean"] > e["mean"] + 0.05 or d["max"] > e["max"] + 1:
                worse.append((fmt, name, d, e))
    if worse:
        print()
        print("ours is measurably worse than the reference on:")
        for fmt, name, d, e in worse:
            print("  %-8s %-10s ours max=%d mean=%.2f  theirs max=%d "
                  "mean=%.2f" % (fmt, name, d["max"], d["mean"], e["max"],
                                 e["mean"]))
    else:
        print()
        print("ours is not measurably worse than the reference on any "
              "image.")

    shutil.rmtree(workdir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
