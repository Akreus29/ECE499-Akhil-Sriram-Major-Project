#!/usr/bin/env python3
"""
gen_target_mem.py — bake the target-designation frame into BRAM init files.

Produces data/target_frame.mem: 38,400 lines of 4-hex-digit words, one per
16-bit frame-buffer word (word w = {gray[2w+1], gray[2w]}), exactly the
layout frame_input_if.sv stores after its RGB565->grayscale conversion.
The IP preloads this into the frame BRAM at configuration and self-runs the
designation sequence at boot (AUTO_TINIT), so runtime needs no designation
upload: NCC acquires from the very first camera frame.

The pixel pipeline mirrors the RTL bit-exactly:
  photo -> centre-crop to 4:3 -> resize 320x240 -> RGB565 quantize ->
  luma = (77*r8 + 150*g8 + 29*b8) >> 8   with MSB-replicated components.

Usage:
  python scripts/gen_target_mem.py "ping pong ball.png"          # auto centre
  python scripts/gen_target_mem.py photo.png --row 118 --col 161 # manual
  python scripts/gen_target_mem.py --synthetic                   # TB pattern
"""

import argparse
import os
import sys

from PIL import Image

FRAME_W, FRAME_H = 320, 240
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")


def rtl_luma(r, g, b):
    """Bit-exact mirror of frame_input_if.sv's rgb565_gray()."""
    r5, g6, b5 = r >> 3, g >> 2, b >> 3
    r8 = (r5 << 3) | (r5 >> 2)
    g8 = (g6 << 2) | (g6 >> 4)
    b8 = (b5 << 3) | (b5 >> 2)
    return (77 * r8 + 150 * g8 + 29 * b8) >> 8


def load_photo(path):
    im = Image.open(path).convert("RGB")
    # centre-crop to 4:3 then resize
    w, h = im.size
    tgt_ar = FRAME_W / FRAME_H
    if w / h > tgt_ar:
        new_w = int(h * tgt_ar)
        x0 = (w - new_w) // 2
        im = im.crop((x0, 0, x0 + new_w, h))
    else:
        new_h = int(w / tgt_ar)
        y0 = (h - new_h) // 2
        im = im.crop((0, y0, w, y0 + new_h))
    im = im.resize((FRAME_W, FRAME_H), Image.LANCZOS)

    gray = [[0] * FRAME_W for _ in range(FRAME_H)]
    px = im.load()
    for r in range(FRAME_H):
        for c in range(FRAME_W):
            gray[r][c] = rtl_luma(*px[c, r])
    return gray


def synthetic_frame(cr=120, cc=160):
    """TB pattern: 8x8 bright ball (0xF0) on dark bg (0x18), matching the
    testbench's rgb565_of_gray()+luma round trip."""
    def rt(g):
        return rtl_luma((g >> 3) << 3, (g >> 2) << 2, (g >> 3) << 3)
    bg, ball = rt(0x18), rt(0xF0)
    gray = [[bg] * FRAME_W for _ in range(FRAME_H)]
    for r in range(cr - 4, cr + 4):
        for c in range(cc - 4, cc + 4):
            gray[r][c] = ball
    return gray


def autodetect_centre(gray):
    """Centroid of pixels that differ most from the median background."""
    flat = sorted(v for row in gray for v in row)
    med = flat[len(flat) // 2]
    # target pixels = strong deviation from background level
    thr = 40
    sr = sc = n = 0
    for r in range(FRAME_H):
        for c in range(FRAME_W):
            if abs(gray[r][c] - med) > thr:
                sr += r
                sc += c
                n += 1
    if n < 16:
        print("WARNING: target auto-detect found almost nothing; "
              "defaulting to frame centre")
        return FRAME_H // 2, FRAME_W // 2
    return sr // n, sc // n


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def ascii_preview(gray, mark=None):
    """Render the 320x240 gray frame as ~80x30 ASCII so we can eyeball the
    target location.  `mark` = (row,col) draws an 'X'."""
    ramp = " .:-=+*#%@"
    ph, pw = 30, 80
    lines = []
    for pr in range(ph):
        row = []
        for pc in range(pw):
            r = pr * FRAME_H // ph
            c = pc * FRAME_W // pw
            if mark and abs(pr - mark[0] * ph // FRAME_H) <= 0 \
                    and abs(pc - mark[1] * pw // FRAME_W) <= 0:
                row.append("X")
            else:
                row.append(ramp[min(9, gray[r][c] * 10 // 256)])
        lines.append("".join(row))
    return "\n".join(lines)


def template_stats(gray, cr, cc):
    """Mirror the tinit engine: 64x64 crop -> 16x16 4x4-means -> mean, Et."""
    top, left = cr - 32, cc - 32
    tmpl = [[0] * 16 for _ in range(16)]
    tsum = 0
    for br in range(16):
        for bc in range(16):
            acc = 0
            for i in range(4):
                for j in range(4):
                    acc += gray[top + 4 * br + i][left + 4 * bc + j]
            tmpl[br][bc] = acc >> 4
    tsum = sum(gray[top + i][left + j] for i in range(64) for j in range(64))
    mean = tsum >> 12
    et = sum((tmpl[i][j] - mean) ** 2 for i in range(16) for j in range(16))
    return mean, et


def write_mem(gray, path):
    with open(path, "w") as f:
        for w in range(FRAME_W * FRAME_H // 2):
            lo = gray[(2 * w) // FRAME_W][(2 * w) % FRAME_W]
            hi = gray[(2 * w + 1) // FRAME_W][(2 * w + 1) % FRAME_W]
            f.write(f"{(hi << 8) | lo:04x}\n")
    print(f"  wrote {path}  ({FRAME_W * FRAME_H // 2} words)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("photo", nargs="?", help="designation photo")
    ap.add_argument("--row", type=int, help="target centre row (0-239)")
    ap.add_argument("--col", type=int, help="target centre col (0-319)")
    ap.add_argument("--synthetic", action="store_true",
                    help="emit tb_target_frame.mem (TB ball at 120,160)")
    ap.add_argument("--outfile", help="output .mem name (default target_frame.mem)")
    ap.add_argument("--preview", action="store_true",
                    help="print an ASCII thumbnail and exit (no .mem written)")
    args = ap.parse_args()

    os.makedirs(DATA, exist_ok=True)

    if args.synthetic:
        gray = synthetic_frame(120, 160)
        write_mem(gray, os.path.join(DATA, "tb_target_frame.mem"))
        mean, et = template_stats(gray, 120, 160)
        print(f"  synthetic centre=(120,160)  tmpl mean={mean}  Et={et}")
        return

    if not args.photo:
        ap.error("photo path required (or --synthetic)")

    gray = load_photo(args.photo)
    if args.row is not None and args.col is not None:
        cr, cc = args.row, args.col
    else:
        cr, cc = autodetect_centre(gray)
        print(f"  auto-detected target centre: row={cr} col={cc}")
    cr = clamp(cr, 32, FRAME_H - 32)
    cc = clamp(cc, 32, FRAME_W - 32)

    if args.preview:
        print(ascii_preview(gray, mark=(cr, cc)))
        print(f"  (X = centre row={cr} col={cc})")
        return

    outfile = args.outfile or "target_frame.mem"
    write_mem(gray, os.path.join(DATA, outfile))
    mean, et = template_stats(gray, cr, cc)
    print(f"  target centre (clamped): row={cr} col={cc}")
    print(f"  template stats: mean={mean}  Et={et}")
    print(f"\n  RTL parameters for image_ip_axilite:")
    print(f"    .TGT_ROW(9'd{cr}), .TGT_COL(9'd{cc})")


if __name__ == "__main__":
    main()
