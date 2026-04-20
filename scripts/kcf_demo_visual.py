"""
kcf_demo_visual.py — Interactive 3-frame NCC→KCF tracking demo.

  1. Frame 1 (Demo_test_1): Click to select target → Train KCF
  2. Frame 1: KCF self-test — peak at (0,0), explains training formula
  3. Frame 2 (Demo_test_2): Show new frame
  4. Frame 2: NCC full-image search → TARGET FOUND, explains NCC formula
  5. "Switching to KCF tracking..." — explains NCC vs KCF complexity
  6. Frame 3 (shifted): KCF ONLY → detection formula + displacement
  7. Summary

Usage:
  python scripts/kcf_demo_visual.py
"""

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import os, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR   = os.path.join(SCRIPT_DIR, '..')
sys.path.insert(0, SCRIPT_DIR)

from kcf_real_image import (
    float_to_q88, write_mem, load_image_gray, crop_patch,
    make_hann, train_alpha, detect,
    N, FRAC, SCALE,
)

DATA_DIR = os.path.join(ROOT_DIR, 'data')
IMG1_PATH = os.path.join(DATA_DIR, 'Demo_test_1.png')
IMG2_PATH = os.path.join(DATA_DIR, 'Demo_test_2.png')

# Simulated inter-frame shift for Frame 3 (pixels): target moves this much
# Positive = target shifts down/right in Frame 3 relative to Frame 2
FRAME3_SHIFT = (8, 7)  # (row_shift, col_shift) — max reliable: ~10.6px total


# ── NCC search ────────────────────────────────────────────────────────────────

def ncc_search(image, target_patch):
    H, W = image.shape
    template = target_patch - target_patch.mean()
    t_norm = np.linalg.norm(template)
    t_pad = np.zeros((H, W)); t_pad[:N, :N] = template
    T = np.fft.fft2(t_pad); I = np.fft.fft2(image)
    corr = np.fft.ifft2(np.conj(T) * I).real
    mask = np.zeros((H, W)); mask[:N, :N] = 1.0
    M = np.fft.fft2(mask)
    ls = np.fft.ifft2(np.conj(M) * I).real; lm = ls / (N*N)
    lsq = np.fft.ifft2(np.conj(M) * np.fft.fft2(image**2)).real
    lv = lsq / (N*N) - lm**2
    lstd = np.sqrt(np.maximum(lv, 1e-10))
    ncc = corr / np.maximum(t_norm * N * lstd, 1e-10)
    # Only search valid positions where full patch fits (no FFT wrap-around)
    valid = ncc[:H - N + 1, :W - N + 1]
    pk = np.argmax(valid)
    r, c = pk // valid.shape[1], pk % valid.shape[1]
    return ncc, r, c, float(ncc[r, c])


def signed_disp(raw_r, raw_c):
    dr = raw_r if raw_r < N // 2 else raw_r - N
    dc = raw_c if raw_c < N // 2 else raw_c - N
    return dr, dc


# ── .mem writers ──────────────────────────────────────────────────────────────

def write_alpha_mem(alpha_hat, X_hat_train):
    combined = np.conj(alpha_hat) * X_hat_train
    K = 1
    while K * 2 * np.max(np.abs(combined)) < 120.0:
        K *= 2
    K = max(K, 1)
    scaled = combined * K
    vals = []
    for r in range(N):
        for c in range(N):
            vals.append(float_to_q88(scaled[r, c].real))
            vals.append(float_to_q88(scaled[r, c].imag))
    write_mem('alpha_hat.mem', vals)
    return K


def write_patch_mem(patch, fname):
    vals = [float_to_q88(patch[r, c]) for r in range(N) for c in range(N)]
    write_mem(fname, vals)


def write_threshold_mem(q88):
    path = os.path.join(DATA_DIR, 'conf_threshold.mem')
    with open(path, 'w') as f:
        f.write(f'{q88 & 0xFFFF:04x}\n')


# ── Wait for click / keypress ────────────────────────────────────────────────

def wait(fig, msg=''):
    if msg:
        print(f'  >> {msg}')
    fig.canvas.flush_events()
    plt.waitforbuttonpress()


# ── Styled info panel ─────────────────────────────────────────────────────────

def info_panel(fig, title, title_color, lines, ec='white'):
    """Draw the right-side info panel. lines = list of (text, color, size, bold)."""
    # Build a single string — matplotlib doesn't support per-line styling in fig.text,
    # so we use a pre-formatted monospace block with Unicode box chars for sections.
    body = f'{title}\n{"─" * max(len(l[0]) for l in lines)}\n'
    for text, *_ in lines:
        body += f'{text}\n'
    # Find dominant color for bbox border
    return fig.text(0.795, 0.50, body, fontsize=11, color='white',
                    ha='center', va='center', fontfamily='monospace',
                    bbox=dict(fc='#111111', ec=title_color, lw=2, pad=14))


# ── MAIN ──────────────────────────────────────────────────────────────────────

def main():
    os.makedirs(DATA_DIR, exist_ok=True)

    print('Loading images...')
    img1 = load_image_gray(IMG1_PATH)
    img2 = load_image_gray(IMG2_PATH)
    # Generate Frame 3 by shifting Frame 2 — simulates small camera pan
    sr, sc = FRAME3_SHIFT
    img3 = np.roll(np.roll(img2, sr, axis=0), sc, axis=1)
    print(f'  Frame 3 generated from Frame 2 with shift ({sr:+d}, {sc:+d}) px')
    hann_1d = make_hann()
    half = N // 2

    STEPS = 7
    fig = plt.figure(figsize=(16, 9))
    fig.patch.set_facecolor('black')

    # ══════════════════════════════════════════════════════════════════════
    #  STEP 1: Show Frame 1 → click to select target
    # ══════════════════════════════════════════════════════════════════════
    ax_img = fig.add_axes([0.02, 0.08, 0.55, 0.82])
    ax_img.imshow(img1, cmap='gray', vmin=0, vmax=1)
    ax_img.set_title('Frame 1  (Demo_test_1)  —  CLICK on target centre',
                     fontsize=16, fontweight='bold', color='red', pad=10)
    ax_img.axis('off')

    fig.text(0.795, 0.50,
             'Step 1 / 7  ─  SELECT TARGET\n'
             '─────────────────────────────\n'
             'Click the object you want\n'
             'to track.\n\n'
             'KCF will memorise its\n'
             f'texture in a {N}x{N} patch\n'
             'and learn a frequency-\n'
             'domain filter from it.\n\n'
             '(click image to select)',
             fontsize=11, color='white', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#111111', ec='red', lw=2, pad=14))
    plt.show(block=False)
    fig.canvas.draw()
    print('  >> Step 1: Click on Frame 1 to select target centre...')

    click = plt.ginput(1, timeout=0)
    click_x, click_y = click[0]
    c1_c = int(round(click_x))
    c1_r = int(round(click_y))
    c1_r = max(half, min(c1_r, img1.shape[0] - half))
    c1_c = max(half, min(c1_c, img1.shape[1] - half))
    print(f'  >> Target selected at ({c1_r}, {c1_c})')

    t_r0 = c1_r - half
    t_c0 = c1_c - half
    target = img1[t_r0:t_r0+N, t_c0:t_c0+N]

    rect_t = Rectangle((t_c0, t_r0), N, N, lw=3, edgecolor='red',
                        facecolor='none', linestyle='--')
    ax_img.add_patch(rect_t)
    ax_img.plot(c1_c, c1_r, '+', color='red', ms=20, mew=3)
    ax_img.set_title(f'Frame 1  |  Target selected at ({c1_r}, {c1_c})',
                     fontsize=16, fontweight='bold', color='white', pad=10)

    for child in fig.texts[:]:
        child.remove()
    fig.text(0.795, 0.50,
             'Step 1 / 7  ─  TARGET SELECTED\n'
             '─────────────────────────────────\n'
             f'  centre = ({c1_r}, {c1_c})\n'
             f'  patch  = {N}x{N} px\n\n'
             'Training KCF filter...\n\n'
             '(click to see response)',
             fontsize=11, color='white', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#111111', ec='red', lw=2, pad=14))
    fig.canvas.draw()

    # Train KCF
    print('  Training KCF on selected target...')
    alpha_hat, X_hat_train, _ = train_alpha(target, hann_1d)
    K = write_alpha_mem(alpha_hat, X_hat_train)

    # KCF self-test on Frame 1
    pk1_r, pk1_c, resp1, _ = detect(target, alpha_hat, X_hat_train, hann_1d)
    d1_r, d1_c = signed_disp(pk1_r, pk1_c)

    # ── Pre-compute Frame 2 NCC + Frame 3 KCF ─────────────────────────
    print('  Running NCC on Frame 2...')
    ncc2, tl2_r, tl2_c, ncc2_val = ncc_search(img2, target)
    c2_r, c2_c = tl2_r + half, tl2_c + half

    p2_r = max(0, min(tl2_r, img2.shape[0] - N))
    p2_c = max(0, min(tl2_c, img2.shape[1] - N))
    patch2 = img2[p2_r:p2_r+N, p2_c:p2_c+N]

    # Frame 3: KCF ONLY at the same position NCC found in Frame 2
    p3_r = max(0, min(tl2_r, img3.shape[0] - N))
    p3_c = max(0, min(tl2_c, img3.shape[1] - N))
    patch3 = img3[p3_r:p3_r+N, p3_c:p3_c+N]
    pk3_r, pk3_c, resp3, _ = detect(patch3, alpha_hat, X_hat_train, hann_1d)
    d3_r, d3_c = signed_disp(pk3_r, pk3_c)

    hw1 = resp1[pk1_r, pk1_c] * K / N
    hw3 = resp3[pk3_r, pk3_c] * K / N

    # Write .mem files
    write_patch_mem(target, 'test_patch_32.mem')
    write_patch_mem(patch3, 'test2_patch_32.mem')
    thresh_q88 = max(1, int(round(min(hw1, hw3) * 0.5 * SCALE)))
    write_threshold_mem(thresh_q88)

    resp1_s = np.fft.fftshift(resp1)
    resp3_s = np.fft.fftshift(resp3)
    ext = [-half, half, half, -half]

    # KCF-corrected position in Frame 3
    c3_r = p3_r + half + d3_r
    c3_c = p3_c + half + d3_c

    print(f'  Frame 1 target:    ({c1_r}, {c1_c})  [clicked]')
    print(f'  Frame 2 NCC:       ({c2_r}, {c2_c})  NCC={ncc2_val:.3f}')
    print(f'  Frame 3 KCF disp:  ({d3_r:+d}, {d3_c:+d})  centre=({c3_r}, {c3_c})')
    print(f'  .mem files written to data/')

    wait(fig, 'Click to see KCF training response')

    # ══════════════════════════════════════════════════════════════════════
    #  STEP 2: KCF trained → response peak at centre
    # ══════════════════════════════════════════════════════════════════════
    for child in fig.texts[:]:
        child.remove()

    ax_img.set_title('Frame 1  |  KCF Filter Trained',
                     fontsize=15, fontweight='bold', color='cyan', pad=10)

    ax_kcf = fig.add_axes([0.58, 0.38, 0.20, 0.48])
    ax_kcf.imshow(resp1_s, cmap='hot', interpolation='nearest', extent=ext)
    ax_kcf.plot(d1_c, d1_r, 'c*', ms=18, mec='white', mew=2)
    ax_kcf.axhline(0, color='white', lw=0.5, alpha=0.4)
    ax_kcf.axvline(0, color='white', lw=0.5, alpha=0.4)
    ax_kcf.set_title(f'Response  peak=({d1_r:+d},{d1_c:+d})',
                     fontsize=10, fontweight='bold', color='cyan', pad=5)
    ax_kcf.set_xlabel('col disp', color='white', fontsize=8)
    ax_kcf.set_ylabel('row disp', color='white', fontsize=8)
    ax_kcf.tick_params(colors='white', labelsize=7)
    for spine in ax_kcf.spines.values():
        spine.set_edgecolor('white')

    fig.text(0.895, 0.50,
             'Step 2 / 7  ─  KCF TRAINING\n'
             '──────────────────────────────\n'
             'ALGORITHM:\n'
             '  w  = patch x Hann2D\n'
             '  X  = FFT2(w)\n'
             '  Y  = FFT2(Gaussian label)\n'
             '  a  = Y / (|X|^2 + lambda)\n\n'
             f'  lambda = 0.01  (ridge reg.)\n'
             f'  sigma  = 2.0   (label width)\n\n'
             'RESULT:\n'
             '  Peak at (0,0) = target is\n'
             '  centred in its own window.\n'
             '  Filter a is frozen for\n'
             '  tracking in future frames.\n\n'
             '(click to continue)',
             fontsize=10, color='white', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#111111', ec='cyan', lw=2, pad=12))
    fig.canvas.draw()
    wait(fig, 'Step 2: KCF trained - peak at (0,0)')

    # ══════════════════════════════════════════════════════════════════════
    #  STEP 3: Show Frame 2
    # ══════════════════════════════════════════════════════════════════════
    for child in fig.texts[:]:
        child.remove()
    ax_kcf.clear(); ax_kcf.axis('off')
    ax_img.clear()
    ax_img.imshow(img2, cmap='gray', vmin=0, vmax=1)
    ax_img.set_title('Frame 2  (Demo_test_2)  —  New frame received',
                     fontsize=16, fontweight='bold', color='white', pad=10)
    ax_img.axis('off')

    fig.text(0.795, 0.50,
             'Step 3 / 7  ─  FRAME 2\n'
             '───────────────────────────\n'
             'New frame has arrived.\n\n'
             'The camera panned —\n'
             'the target has moved.\n\n'
             'WHERE is it now?\n\n'
             'Running NCC to search\n'
             'the entire image...\n\n'
             '(click to run NCC)',
             fontsize=11, color='white', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#111111', ec='white', lw=2, pad=14))
    fig.canvas.draw()
    wait(fig, 'Step 3: Showing Frame 2')

    # ══════════════════════════════════════════════════════════════════════
    #  STEP 4: NCC search on Frame 2 → TARGET FOUND
    # ══════════════════════════════════════════════════════════════════════
    for child in fig.texts[:]:
        child.remove()

    vmax2 = max(np.percentile(ncc2, 99.5), 0.8)
    ax_img.imshow(ncc2, cmap='jet', alpha=0.45, interpolation='bilinear',
                  vmin=0, vmax=vmax2)
    rect2 = Rectangle((tl2_c, tl2_r), N, N, lw=3, edgecolor='lime',
                       facecolor='none')
    ax_img.add_patch(rect2)
    ax_img.plot(c2_c, c2_r, '+', color='lime', ms=20, mew=3)
    ax_img.set_title(f'Frame 2  |  NCC Search  |  TARGET FOUND at ({c2_r}, {c2_c})',
                     fontsize=15, fontweight='bold', color='lime', pad=10)

    fig.text(0.795, 0.50,
             'Step 4 / 7  ─  NCC SEARCH\n'
             '──────────────────────────────\n'
             'ALGORITHM:\n'
             '  corr = IFFT(conj(T)*I)\n'
             '  NCC  = corr /\n'
             '    (||t|| x N x sigma_local)\n\n'
             'Complexity: O(MN log MN)\n'
             'Searches full image at once.\n\n'
             'RESULT:\n'
             f'  centre = ({c2_r}, {c2_c})\n'
             f'  score  = {ncc2_val:.4f}\n\n'
             '>>> TARGET FOUND <<<\n\n'
             'Used ONCE for NCC->KCF\n'
             'handoff. Too slow for\n'
             'every frame.\n\n'
             '(click to hand off to KCF)',
             fontsize=10, color='lime', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#111111', ec='lime', lw=2, pad=12))
    fig.canvas.draw()
    wait(fig, 'Step 4: NCC found target in Frame 2')

    # ══════════════════════════════════════════════════════════════════════
    #  STEP 5: "Switching to KCF tracking..."
    # ══════════════════════════════════════════════════════════════════════
    for child in fig.texts[:]:
        child.remove()

    ax_img.set_title('Switching to KCF Tracking...',
                     fontsize=20, fontweight='bold', color='yellow', pad=10)

    fig.text(0.50, 0.50,
             'Step 5 / 7  ─  NCC  -->  KCF  HANDOFF\n'
             '══════════════════════════════════════════\n\n'
             '  NCC (Normalised Cross-Correlation)\n'
             '  Complexity : O(M*N * log(M*N))\n'
             '  Searches   : entire M*N image\n'
             '  Use case   : initial target acquisition\n\n'
             '  KCF (Kernelised Correlation Filter)\n'
             '  Complexity : O(N^2 * log(N^2))\n'
             '  Searches   : fixed N x N local window\n'
             '  Use case   : per-frame tracking (fast)\n\n'
             '  NCC position passed to KCF as the\n'
             '  initial window centre. From here,\n'
             '  ONLY KCF runs — no more NCC.\n\n'
             '  KCF runs in HARDWARE (FPGA) on the\n'
             '  32x32 window received via AXI-Stream.\n\n'
             '(click to see KCF track Frame 3)',
             fontsize=13, color='yellow', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#111111', ec='yellow', lw=3, pad=22))
    fig.canvas.draw()
    wait(fig, 'Step 5: Switching to KCF tracking...')

    # ══════════════════════════════════════════════════════════════════════
    #  STEP 6: Frame 3 — KCF ONLY at last known position
    # ══════════════════════════════════════════════════════════════════════
    for child in fig.texts[:]:
        child.remove()

    ax_img.clear()
    ax_img.imshow(img3, cmap='gray', vmin=0, vmax=1)
    ax_img.axis('off')

    # Draw KCF window at last known position (NCC from Frame 2)
    rect_kcf = Rectangle((p3_c, p3_r), N, N, lw=3, edgecolor='yellow',
                          facecolor='none', linestyle='--')
    ax_img.add_patch(rect_kcf)
    ax_img.plot(c3_c, c3_r, 'x', color='cyan', ms=18, mew=3)

    disp_dir = []
    if d3_c > 0: disp_dir.append(f'{d3_c:+d} px right')
    elif d3_c < 0: disp_dir.append(f'{d3_c:+d} px left')
    if d3_r > 0: disp_dir.append(f'{d3_r:+d} px down')
    elif d3_r < 0: disp_dir.append(f'{d3_r:+d} px up')
    disp_str = ', '.join(disp_dir) if disp_dir else 'no displacement'

    ax_img.set_title(f'Frame 3  (shifted +{sr}r,+{sc}c)  |  KCF ONLY  |  {disp_str}',
                     fontsize=14, fontweight='bold', color='yellow', pad=10)

    # KCF response plot — smaller, leaving room for text panel
    ax_kcf.clear()
    ax_kcf.set_visible(True)
    ax_kcf.imshow(resp3_s, cmap='hot', interpolation='nearest', extent=ext)
    ax_kcf.plot(d3_c, d3_r, 'c*', ms=22, mec='white', mew=2)
    ax_kcf.axhline(0, color='white', lw=0.5, alpha=0.4)
    ax_kcf.axvline(0, color='white', lw=0.5, alpha=0.4)

    if d3_r != 0 or d3_c != 0:
        ax_kcf.annotate('', xy=(d3_c, d3_r), xytext=(0, 0),
                        arrowprops=dict(arrowstyle='->', color='cyan', lw=2.5))
        ax_kcf.text(d3_c + 1, d3_r - 1.5,
                    f'({d3_r:+d}, {d3_c:+d})',
                    color='cyan', fontsize=12, fontweight='bold',
                    bbox=dict(fc='black', alpha=0.7, pad=3))

    ax_kcf.set_title(f'KCF Response  peak=({d3_r:+d},{d3_c:+d})',
                     fontsize=11, fontweight='bold', color='yellow', pad=6)
    ax_kcf.set_xlabel('col displacement', color='white', fontsize=9)
    ax_kcf.set_ylabel('row displacement', color='white', fontsize=9)
    ax_kcf.tick_params(colors='white', labelsize=8)
    for spine in ax_kcf.spines.values():
        spine.set_edgecolor('white')

    fig.text(0.895, 0.50,
             'Step 6 / 7  ─  KCF TRACKING\n'
             '──────────────────────────────\n'
             'ALGORITHM (FPGA runs this):\n'
             '  w = patch x Hann2D\n'
             '  Z = FFT2(w)\n'
             '  R = IFFT2(conj(X)*Z*a)\n'
             '  peak(R) -> displacement\n\n'
             'Window centred at NCC pos.\n'
             'No full-image search needed.\n\n'
             'RESULT:\n'
             f'  KCF peak = ({d3_r:+d}, {d3_c:+d})\n'
             f'  = {disp_str}\n'
             f'  Tracked to ({c3_r}, {c3_c})\n\n'
             'Hardware pipeline:\n'
             '  Hann->FFT->cmul->IFFT\n'
             '  ->peak_finder\n\n'
             '(click for summary)',
             fontsize=10, color='yellow', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#111111', ec='yellow', lw=2, pad=12))
    fig.canvas.draw()
    wait(fig, 'Step 6: KCF-only tracking on Frame 3')

    # ══════════════════════════════════════════════════════════════════════
    #  STEP 7: Final summary
    # ══════════════════════════════════════════════════════════════════════
    for child in fig.texts[:]:
        child.remove()
    ax_img.clear(); ax_img.axis('off')
    ax_kcf.clear(); ax_kcf.axis('off')

    # Side-by-side KCF responses
    ax_r1 = fig.add_axes([0.03, 0.15, 0.27, 0.65])
    ax_r1.imshow(resp1_s, cmap='hot', interpolation='nearest', extent=ext)
    ax_r1.plot(d1_c, d1_r, 'c*', ms=20, mec='white', mew=2)
    ax_r1.axhline(0, color='white', lw=0.5, alpha=0.3)
    ax_r1.axvline(0, color='white', lw=0.5, alpha=0.3)
    ax_r1.set_title(f'Frame 1  KCF (train)\npeak = ({d1_r:+d}, {d1_c:+d})',
                    fontsize=11, fontweight='bold', color='lime')
    ax_r1.tick_params(colors='white', labelsize=8)
    ax_r1.set_xlabel('col disp', color='white', fontsize=8)
    ax_r1.set_ylabel('row disp', color='white', fontsize=8)

    ax_r3 = fig.add_axes([0.33, 0.15, 0.27, 0.65])
    ax_r3.imshow(resp3_s, cmap='hot', interpolation='nearest', extent=ext)
    ax_r3.plot(d3_c, d3_r, 'c*', ms=20, mec='white', mew=2)
    if d3_r != 0 or d3_c != 0:
        ax_r3.annotate('', xy=(d3_c, d3_r), xytext=(0, 0),
                       arrowprops=dict(arrowstyle='->', color='cyan', lw=2))
    ax_r3.axhline(0, color='white', lw=0.5, alpha=0.3)
    ax_r3.axvline(0, color='white', lw=0.5, alpha=0.3)
    ax_r3.set_title(f'Frame 3  KCF (track)\npeak = ({d3_r:+d}, {d3_c:+d})',
                    fontsize=11, fontweight='bold', color='yellow')
    ax_r3.tick_params(colors='white', labelsize=8)
    ax_r3.set_xlabel('col disp', color='white', fontsize=8)
    ax_r3.set_ylabel('row disp', color='white', fontsize=8)

    fig.text(0.795, 0.50,
             'SUMMARY\n'
             '══════════════════════════════\n\n'
             'FRAME 1 (Demo_test_1)\n'
             f'  Target:  ({c1_r}, {c1_c})  [clicked]\n'
             f'  KCF:     peak ({d1_r:+d}, {d1_c:+d})\n\n'
             'FRAME 2 (Demo_test_2)\n'
             '  Method:  NCC full-image\n'
             f'  Found:   ({c2_r}, {c2_c})\n'
             f'  Score:   {ncc2_val:.4f}\n\n'
             'FRAME 3 (shifted)\n'
             '  Method:  KCF only (no NCC)\n'
             f'  Disp:    ({d3_r:+d}, {d3_c:+d})\n'
             f'  Tracked: ({c3_r}, {c3_c})\n\n'
             'NCC located. KCF tracked.\n'
             'FPGA runs KCF via AXI.\n'
             '.mem files -> data/',
             fontsize=10, color='white', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#111111', ec='white', lw=2, pad=16))

    fig.text(0.32, 0.93,
             f'NCC->KCF Tracking Demo  |  Frame2 NCC: ({c2_r},{c2_c})  |  '
             f'Frame3 KCF: ({d3_r:+d},{d3_c:+d})',
             fontsize=13, fontweight='bold', color='white',
             ha='center', va='center')

    fig.canvas.draw()
    print(f'\n  >> Step 7: Final summary. Close the window to exit.')
    plt.show(block=True)


if __name__ == '__main__':
    main()
