#!/usr/bin/env python3
"""OCR a screenshot and locate UI text -- for the GUI tests (Linux Xvfb and the Win11 VM).

Same recipe as vm/scripts/labtap.py (tesseract deu+eng, 2x upscale), but works on any PNG,
so it serves both the Linux client window and VM screendumps.

  ocr.py lines <png> [--region x,y,w,h]              -> one OCR'd line per row: x y w h text
  ocr.py find  <png> "alt1|alt2" [--region x,y,w,h]  -> "cx cy text" of the first match, exit 1 if none
  ocr.py has   <png> "alt1|alt2" [--region ...]      -> exit 0 if any alternative is on screen

Matching is case-insensitive on whole OCR'd lines: substring first, then fuzzy (ratio >= 0.8
on a same-length window), so "Einstellungen ..." matches "Einstellungen".
Coordinates are in the ORIGINAL image's pixels (region offset added back).
"""
import difflib, os, subprocess, sys, tempfile
from PIL import Image, ImageOps

TESSDATA = os.environ.get("TESSDATA_PREFIX", "/projects/rustdesk/vm/tessdata")


def ocr_lines(png, region=None):
    im = Image.open(png).convert("RGB")
    xoff = yoff = 0
    if region:
        x, y, w, h = region
        im = im.crop((x, y, x + w, y + h)); xoff, yoff = x, y
    lines = []
    # Three passes: as-is; inverted (white-on-dark consoles, highlighted menu rows); and the
    # red channel alone at 3x, which turns teal/green/blue text (the "Registriert" status,
    # links) almost black on white -- tesseract misses it in colour and in plain grayscale
    # on the Linux rendering.
    red = ImageOps.autocontrast(im.split()[0]).convert("RGB")
    for variant, scale in ((im, 2), (ImageOps.invert(im), 2), (red, 3)):
        big = variant.resize((variant.width * scale, variant.height * scale), Image.LANCZOS)
        fd, p = tempfile.mkstemp(suffix=".png"); os.close(fd); big.save(p)
        tsv = subprocess.run(["tesseract", p, "stdout", "-l", "deu+eng", "--psm", "11", "tsv"],
                             capture_output=True, text=True,
                             env=dict(os.environ, TESSDATA_PREFIX=TESSDATA)).stdout
        os.unlink(p)
        rows = {}
        for row in tsv.splitlines()[1:]:
            c = row.split("\t")
            if len(c) < 12 or not c[11].strip():
                continue
            try:
                if float(c[10]) < 30:
                    continue
            except ValueError:
                continue
            key = (c[2], c[3], c[4])  # block, paragraph, line
            l, t, w, h = (int(v) // scale for v in c[6:10])
            r = rows.setdefault(key, [l, t, l + w, t + h, []])
            r[0] = min(r[0], l); r[1] = min(r[1], t); r[2] = max(r[2], l + w); r[3] = max(r[3], t + h)
            r[4].append(c[11])
        for l, t, rr, bb, words in rows.values():
            lines.append((l + xoff, t + yoff, rr - l, bb - t, " ".join(words)))
    return lines


def match(text, alt):
    a, t = alt.lower().strip(), text.lower()
    if a in t:
        return True
    n = len(a)
    return any(difflib.SequenceMatcher(None, a, t[i:i + n]).ratio() >= 0.8 for i in range(max(1, len(t) - n + 1)))


def find(png, alts, region=None):
    lines = ocr_lines(png, region)
    for alt in alts.split("|"):
        for (x, y, w, h, text) in lines:
            if match(text, alt):
                return x + w // 2, y + h // 2, text
    return None


def main():
    args = sys.argv[1:]
    region = None
    if "--region" in args:
        i = args.index("--region"); region = tuple(int(v) for v in args[i + 1].split(",")); del args[i:i + 2]
    cmd, png = args[0], args[1]
    if cmd == "lines":
        for (x, y, w, h, text) in ocr_lines(png, region):
            print(x, y, w, h, text)
    elif cmd in ("find", "has"):
        r = find(png, args[2], region)
        if not r:
            sys.exit(1)
        if cmd == "find":
            print(r[0], r[1], r[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
