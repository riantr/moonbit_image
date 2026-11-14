"""Mutation check: break one codec at a time and confirm the tests catch it.

A test suite that stays green under mutation is worthless, so this script
is the evidence that the codec decode tests actually discriminate.

Each mutation is applied to a COPY of the module tree, so the working copy
is never touched.

Usage (from anywhere):

    python .tools/mutation_check.py

Expected output: every mutation reported as CAUGHT. A MISSED entry means
that mutation slipped through the test suite and the corresponding
assertion needs to be strengthened. UNKNOWN means the run produced neither
a test summary nor a crash marker, i.e. the result is inconclusive -- it is
never counted as caught. The script exits non-zero on MISSED or UNKNOWN.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOON = "moon.exe" if sys.platform == "win32" else "moon"


def run(cmd, cwd, timeout=600):
    # Decode as UTF-8 with replacement: the default locale codec on Windows
    # is GBK, and `moon test` emits bytes (source snippets, diagnostics) that
    # are not valid GBK. A decode error in the reader thread silently
    # truncates the captured stream, which would turn a real MISSED into a
    # bogus "crashed/panicked" verdict.
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


MUTATIONS = [
    # (label, file, old_snippet, new_snippet)
    ("png: wrong stride (bpp 4 -> 3)",
     "png.mbt",
     None, None),          # placeholder, filled below
    ("gif: drop the alpha channel (RGBA -> RGB)",
     "gif.mbt",
     None, None),
    ("tga: grayscale mapped to RGB8 instead of Gray8",
     "tga.mbt",
     None, None),
    ("jpeg: swap R and B channels",
     "jpeg.mbt",
     None, None),
    ("tga: footer scan off-by-one (re-introduce the crash)",
     "lib.mbt",
     "for i = 0; i < sig_len; i = i + 1 {",
     "for i = 0; i < sig_len + 1; i = i + 1 {"),
    ("png: indexed palette not expanded (alpha dropped)",
     "png.mbt",
     "  PC_IDX => PixelFormat::RGBA8",
     "  PC_IDX => PixelFormat::Gray8"),
]


def mutate_png(root):
    p = os.path.join(root, "png.mbt")
    s = open(p, encoding="utf-8").read()
    # out_fmt for RGBA -> RGB8
    old = "  PC_RGBA => PixelFormat::RGBA8"
    new = "  PC_RGBA => PixelFormat::RGB8"
    if old not in s:
        return False
    s = s.replace(old, new, 1)
    open(p, "w", encoding="utf-8", newline="\n").write(s)
    return True


def mutate_gif(root):
    p = os.path.join(root, "gif.mbt")
    s = open(p, encoding="utf-8").read()
    # every RGBA write becomes RGB: change the output buffer size from 4 to 3
    old = "let out_size = out_w * out_h * 4"
    new = "let out_size = out_w * out_h * 3"
    if old not in s:
        return False
    s = s.replace(old, new, 1)
    open(p, "w", encoding="utf-8", newline="\n").write(s)
    return True


def mutate_tga(root):
    p = os.path.join(root, "tga.mbt")
    s = open(p, encoding="utf-8").read()
    # grayscale -> RGB8 instead of Gray8
    old = "PixelFormat::Gray8"
    new = "PixelFormat::RGB8"
    if old not in s:
        return False
    s = s.replace(old, new, 1)
    open(p, "w", encoding="utf-8", newline="\n").write(s)
    return True


def mutate_jpeg(root):
    p = os.path.join(root, "jpeg.mbt")
    s = open(p, encoding="utf-8").read()
    # Swap the R and B coefficients in the YCbCr -> RGB conversion.
    old = "  let r = y + ((5743 * cr_off + 2048) >> 12)"
    new = "  let r = y + ((7258 * cb_off + 2048) >> 12)"
    old2 = "  let b = y + ((7258 * cb_off + 2048) >> 12)"
    new2 = "  let b = y + ((5743 * cr_off + 2048) >> 12)"
    if old not in s or old2 not in s:
        return False
    s = s.replace(old, new, 1).replace(old2, new2, 1)
    open(p, "w", encoding="utf-8", newline="\n").write(s)
    return True


APPLY = {
    "png: wrong stride (bpp 4 -> 3)": mutate_png,
    "gif: drop the alpha channel (RGBA -> RGB)": mutate_gif,
    "tga: grayscale mapped to RGB8 instead of Gray8": mutate_tga,
    "jpeg: swap R and B channels": mutate_jpeg,
}


def main():
    results = []
    for label, fname, old, new in MUTATIONS:
        tmp = tempfile.mkdtemp(prefix="mut_")
        tree = os.path.join(tmp, "pkg")
        shutil.copytree(ROOT, tree,
                        ignore=shutil.ignore_patterns("_build", ".git",
                                                     ".tools", "tools",
                                                     "target"))
        try:
            if label in APPLY:
                ok = APPLY[label](tree)
            else:
                p = os.path.join(tree, fname)
                s = open(p, encoding="utf-8").read()
                if old not in s:
                    print("SKIP  %-52s (snippet not found)" % label)
                    results.append((label, "SKIP", ""))
                    continue
                s = s.replace(old, new, 1)
                open(p, "w", encoding="utf-8", newline="\n").write(s)
                ok = True
            if not ok:
                print("SKIP  %-52s (mutation not applicable)" % label)
                results.append((label, "SKIP", ""))
                continue
            r = run([MOON, "test", "--target", "native"], tree)
            combined = (r.stdout or "") + (r.stderr or "")
            m = re.search(r"Total tests: (\d+), passed: (\d+), failed: (\d+)", combined)
            if m:
                total, passed, failed = m.groups()
                verdict = "CAUGHT" if int(failed) > 0 else "MISSED"
                detail = "total=%s passed=%s failed=%s" % (total, passed, failed)
            elif re.search(r"(?i)panic|stack trace|unhandled exception", combined):
                # The test binary died before printing a summary. That still
                # counts as caught, but only when the output actually shows a
                # crash -- otherwise the run is inconclusive and must not be
                # reported as a pass.
                verdict = "CAUGHT"
                detail = "crashed/panicked (no summary line)"
            else:
                verdict = "UNKNOWN"
                detail = "no summary line and no crash marker (exit=%s)" % r.returncode
            print("%-6s %-52s %s" % (verdict, label, detail))
            results.append((label, verdict, detail))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    print()
    print("=== summary ===")
    for label, verdict, detail in results:
        print("%-6s %s %s" % (verdict, label, detail))
    missed = [r for r in results if r[1] == "MISSED"]
    print()
    print("caught=%d missed=%d skipped=%d unknown=%d" % (
        len([r for r in results if r[1] == "CAUGHT"]),
        len(missed),
        len([r for r in results if r[1] == "SKIP"]),
        len([r for r in results if r[1] == "UNKNOWN"])))
    return 1 if (missed or [r for r in results if r[1] == "UNKNOWN"]) else 0


if __name__ == "__main__":
    sys.exit(main())
