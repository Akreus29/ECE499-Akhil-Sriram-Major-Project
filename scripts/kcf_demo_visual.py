"""
kcf_demo_visual.py — Interactive step-by-step KCF detection + displacement demo.

  1. Show Frame 1 → click to select target centre
  2. Train KCF → show KCF response (peak at 0,0)
  3. Show Frame 2
  4. NCC search → TARGET FOUND
  5. KCF on Frame 2 → peak displaced to the right
  6. Displacement summary

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
IMG1_PATH = os.path.join(ROOT_DIR, 'docs', 'MidTerm Report', 'Real_test_2.png')
IMG2_PATH = os.path.join(ROOT_DIR, 'docs', 'MidTerm Report', 'Real_test_1.png')



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
    pk = np.argmax(ncc); r, c = pk // W, pk % W
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


# ── MAIN ──────────────────────────────────────────────────────────────────────

def main():
    os.makedirs(DATA_DIR, exist_ok=True)

    print('Loading images...')
    img1 = load_image_gray(IMG1_PATH)
    img2 = load_image_gray(IMG2_PATH)
    hann_1d = make_hann()

    STEPS = 6
    fig = plt.figure(figsize=(16, 9))
    fig.patch.set_facecolor('black')

    # ── STEP 1: Show Frame 1 → click to select target ────────────────────
    ax_img = fig.add_axes([0.02, 0.08, 0.55, 0.82])
    ax_img.imshow(img1, cmap='gray', vmin=0, vmax=1)
    ax_img.set_title('Frame 1  (Real_test_2.png)  —  CLICK on target centre',
                     fontsize=16, fontweight='bold', color='red', pad=10)
    ax_img.axis('off')

    fig.text(0.80, 0.5,
             f'Step 1 / {STEPS}\n\n'
             f'Click on the image\n'
             f'to select the\n'
             f'target centre\n\n'
             f'(32x32 patch)',
             fontsize=14, color='white', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#1a1a1a', ec='red', lw=2, pad=15))
    plt.show(block=False)
    fig.canvas.draw()
    print('  >> Step 1: Click on Frame 1 to select target centre...')

    # Wait for mouse click
    click = plt.ginput(1, timeout=0)
    click_x, click_y = click[0]
    c1_c = int(round(click_x))
    c1_r = int(round(click_y))

    # Clamp to valid range
    half = N // 2
    c1_r = max(half, min(c1_r, img1.shape[0] - half))
    c1_c = max(half, min(c1_c, img1.shape[1] - half))
    print(f'  >> Target selected at ({c1_r}, {c1_c})')

    # Show selected target box
    t_r0 = c1_r - half
    t_c0 = c1_c - half
    target = img1[t_r0:t_r0+N, t_c0:t_c0+N]

    rect_t = Rectangle((t_c0, t_r0), N, N, lw=3, edgecolor='red',
                        facecolor='none', linestyle='--')
    ax_img.add_patch(rect_t)
    ax_img.plot(c1_c, c1_r, '+', color='red', ms=20, mew=3)
    ax_img.set_title(f'Frame 1  |  Target at ({c1_r}, {c1_c})',
                     fontsize=16, fontweight='bold', color='white', pad=10)

    for child in fig.texts[:]:
        child.remove()
    fig.text(0.80, 0.5,
             f'Step 1 / {STEPS}\n\n'
             f'Target selected:\n'
             f'  centre = ({c1_r}, {c1_c})\n'
             f'  size   = {N}x{N}\n\n'
             f'Training KCF...\n'
             f'(click to continue)',
             fontsize=14, color='white', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#1a1a1a', ec='red', lw=2, pad=15))
    fig.canvas.draw()

    # Train KCF
    print('  Training KCF on selected target...')
    alpha_hat, X_hat_train, _ = train_alpha(target, hann_1d)
    K = write_alpha_mem(alpha_hat, X_hat_train)

    # KCF self-test on Frame 1
    pk1_r, pk1_c, resp1, _ = detect(target, alpha_hat, X_hat_train, hann_1d)
    d1_r, d1_c = signed_disp(pk1_r, pk1_c)

    # NCC search on Frame 2 (for validation / display)
    print('  Running NCC on Frame 2...')
    ncc2, tl2_r, tl2_c, ncc2_val = ncc_search(img2, target)
    c2_r, c2_c = tl2_r + N//2, tl2_c + N//2

    # KCF on Frame 2: open window at LAST KNOWN position (same as Frame 1 click)
    # This is how real tracking works — KCF searches around previous position.
    p2_r = max(0, min(c1_r - half, img2.shape[0] - N))
    p2_c = max(0, min(c1_c - half, img2.shape[1] - N))
    patch2 = img2[p2_r:p2_r+N, p2_c:p2_c+N]
    pk2_r, pk2_c, resp2, _ = detect(patch2, alpha_hat, X_hat_train, hann_1d)
    d2_r, d2_c = signed_disp(pk2_r, pk2_c)

    hw1 = resp1[pk1_r, pk1_c] * K / N
    hw2 = resp2[pk2_r, pk2_c] * K / N

    # Write .mem files
    write_patch_mem(target, 'test_patch_32.mem')
    write_patch_mem(patch2, 'test2_patch_32.mem')
    thresh_q88 = max(1, int(round(min(hw1, hw2) * 0.5 * SCALE)))
    write_threshold_mem(thresh_q88)

    # NCC coarse displacement
    ncc_disp_row = c2_r - c1_r
    ncc_disp_col = c2_c - c1_c
    ncc_dist = np.sqrt(ncc_disp_row**2 + ncc_disp_col**2)

    resp1_s = np.fft.fftshift(resp1)
    resp2_s = np.fft.fftshift(resp2)
    ext = [-N//2, N//2, N//2, -N//2]

    print(f'  Frame 1 target:    ({c1_r}, {c1_c})  [clicked]')
    print(f'  Frame 2 NCC:       ({c2_r}, {c2_c})')
    print(f'  NCC displacement:  ({ncc_disp_row:+d}, {ncc_disp_col:+d}) = {ncc_dist:.0f} px')
    print(f'  KCF displacement:  ({d2_r:+d}, {d2_c:+d}) within 32x32 window')
    print(f'  .mem files written to data/')

    wait(fig, 'Click to see KCF response')

    # ── STEP 2: KCF trained → response peak at centre ────────────────────
    for child in fig.texts[:]:
        child.remove()

    ax_img.set_title('Frame 1  |  KCF Trained  |  Target confirmed at centre',
                     fontsize=15, fontweight='bold', color='cyan', pad=10)

    ax_kcf = fig.add_axes([0.62, 0.12, 0.35, 0.72])
    ax_kcf.imshow(resp1_s, cmap='hot', interpolation='nearest', extent=ext)
    ax_kcf.plot(d1_c, d1_r, 'c*', ms=22, mec='white', mew=2)
    ax_kcf.axhline(0, color='white', lw=0.5, alpha=0.4)
    ax_kcf.axvline(0, color='white', lw=0.5, alpha=0.4)
    ax_kcf.set_title(f'KCF Response  |  Peak at ({d1_r:+d}, {d1_c:+d})',
                     fontsize=13, fontweight='bold', color='white', pad=8)
    ax_kcf.set_xlabel('Col displacement', color='white')
    ax_kcf.set_ylabel('Row displacement', color='white')
    ax_kcf.tick_params(colors='white')
    for spine in ax_kcf.spines.values():
        spine.set_edgecolor('white')

    fig.text(0.80, 0.92,
             f'Step 2 / {STEPS} — KCF trained, peak at centre  (click to continue)',
             fontsize=11, color='gray', ha='center', va='center')
    fig.canvas.draw()
    wait(fig, 'Step 2: KCF trained — peak at (0,0)')

    # ── STEP 3: Show Frame 2 ─────────────────────────────────────────────
    for child in fig.texts[:]:
        child.remove()
    ax_kcf.clear(); ax_kcf.axis('off')
    ax_img.clear()
    ax_img.imshow(img2, cmap='gray', vmin=0, vmax=1)
    ax_img.set_title('Frame 2  (Real_test_1.png)', fontsize=16,
                     fontweight='bold', color='white', pad=10)
    ax_img.axis('off')

    fig.text(0.80, 0.5,
             f'Step 3 / {STEPS}\n\n'
             f'Frame 2 loaded\n\n'
             f'Where is the target?\n\n'
             f'(click to run NCC search)',
             fontsize=14, color='white', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#1a1a1a', ec='white', lw=2, pad=15))
    fig.canvas.draw()
    wait(fig, 'Step 3: Showing Frame 2')

    # ── STEP 4: NCC search on Frame 2 → TARGET FOUND ─────────────────────
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

    fig.text(0.80, 0.5,
             f'Step 4 / {STEPS}\n\n'
             f'NCC full-image search\n\n'
             f'Target found at:\n'
             f'  centre = ({c2_r}, {c2_c})\n'
             f'  NCC    = {ncc2_val:.3f}\n\n'
             f'NCC Displacement:\n'
             f'  row: {ncc_disp_row:+d} px\n'
             f'  col: {ncc_disp_col:+d} px\n'
             f'  dist: {ncc_dist:.0f} px\n\n'
             f'(click to run KCF at\n'
             f' last known position)',
             fontsize=14, color='lime', ha='center', va='center',
             fontfamily='monospace',
             bbox=dict(fc='#1a1a1a', ec='lime', lw=2, pad=15))
    fig.canvas.draw()
    wait(fig, 'Step 4: NCC found target in Frame 2')

    # ── STEP 5: KCF response Frame 2 — window at last known position ─────
    for child in fig.texts[:]:
        child.remove()

    # Show the KCF window (last known position) on Frame 2 image
    rect_kcf = Rectangle((p2_c, p2_r), N, N, lw=3, edgecolor='yellow',
                          facecolor='none', linestyle='--')
    ax_img.add_patch(rect_kcf)
    ax_img.plot(c1_c, c1_r, 'x', color='yellow', ms=16, mew=3)

    disp_dir = []
    if d2_c > 0: disp_dir.append(f'{d2_c:+d} px right')
    elif d2_c < 0: disp_dir.append(f'{d2_c:+d} px left')
    if d2_r > 0: disp_dir.append(f'{d2_r:+d} px down')
    elif d2_r < 0: disp_dir.append(f'{d2_r:+d} px up')
    disp_str = ', '.join(disp_dir) if disp_dir else 'no displacement'

    ax_kcf.clear()
    ax_kcf.set_visible(True)
    ax_kcf.imshow(resp2_s, cmap='hot', interpolation='nearest', extent=ext)
    ax_kcf.plot(d2_c, d2_r, 'c*', ms=22, mec='white', mew=2)
    ax_kcf.axhline(0, color='white', lw=0.5, alpha=0.4)
    ax_kcf.axvline(0, color='white', lw=0.5, alpha=0.4)

    # Arrow from centre to peak
    if d2_r != 0 or d2_c != 0:
        ax_kcf.annotate('', xy=(d2_c, d2_r), xytext=(0, 0),
                        arrowprops=dict(arrowstyle='->', color='cyan', lw=2.5))
        ax_kcf.text(d2_c + 1, d2_r - 1.5,
                    f'({d2_r:+d}, {d2_c:+d})',
                    color='cyan', fontsize=13, fontweight='bold',
                    bbox=dict(fc='black', alpha=0.7, pad=3))

    ax_kcf.set_title(f'KCF Response  |  Peak at ({d2_r:+d}, {d2_c:+d})',
                     fontsize=13, fontweight='bold', color='yellow', pad=8)
    ax_kcf.set_xlabel('Col displacement', color='white')
    ax_kcf.set_ylabel('Row displacement', color='white')
    ax_kcf.tick_params(colors='white')
    for spine in ax_kcf.spines.values():
        spine.set_edgecolor('white')

    ax_img.set_title(f'Frame 2  |  KCF at last position ({c1_r},{c1_c})  |  {disp_str}',
                     fontsize=14, fontweight='bold', color='yellow', pad=10)

    fig.text(0.80, 0.92,
             f'Step 5 / {STEPS} — KCF: {disp_str}  (click for summary)',
             fontsize=11, color='gray', ha='center', va='center')
    fig.canvas.draw()
    wait(fig, 'Step 5: KCF peak displaced right')

    # ── STEP 6: Final summary ─────────────────────────────────────────────
    for child in fig.texts[:]:
        child.remove()
    ax_img.clear(); ax_img.axis('off')
    ax_kcf.clear(); ax_kcf.axis('off')

    ax_r1 = fig.add_axes([0.03, 0.15, 0.28, 0.65])
    ax_r1.imshow(resp1_s, cmap='hot', interpolation='nearest', extent=ext)
    ax_r1.plot(d1_c, d1_r, 'c*', ms=20, mec='white', mew=2)
    ax_r1.axhline(0, color='white', lw=0.5, alpha=0.3)
    ax_r1.axvline(0, color='white', lw=0.5, alpha=0.3)
    ax_r1.set_title(f'Frame 1 KCF\npeak = ({d1_r:+d}, {d1_c:+d})',
                    fontsize=12, fontweight='bold', color='lime')
    ax_r1.tick_params(colors='white', labelsize=8)

    ax_r2 = fig.add_axes([0.35, 0.15, 0.28, 0.65])
    ax_r2.imshow(resp2_s, cmap='hot', interpolation='nearest', extent=ext)
    ax_r2.plot(d2_c, d2_r, 'c*', ms=20, mec='white', mew=2)
    if d2_r != 0 or d2_c != 0:
        ax_r2.annotate('', xy=(d2_c, d2_r), xytext=(0, 0),
                       arrowprops=dict(arrowstyle='->', color='cyan', lw=2))
    ax_r2.axhline(0, color='white', lw=0.5, alpha=0.3)
    ax_r2.axvline(0, color='white', lw=0.5, alpha=0.3)
    ax_r2.set_title(f'Frame 2 KCF\npeak = ({d2_r:+d}, {d2_c:+d})',
                    fontsize=12, fontweight='bold', color='yellow')
    ax_r2.tick_params(colors='white', labelsize=8)

    summary = (
        f"FRAME 1 (Real_test_2)\n"
        f"  Target:    ({c1_r}, {c1_c})  [clicked]\n"
        f"  KCF peak:  ({d1_r:+d}, {d1_c:+d})\n\n"
        f"FRAME 2 (Real_test_1)\n"
        f"  NCC found: ({c2_r}, {c2_c})\n"
        f"  KCF window at ({c1_r}, {c1_c})\n"
        f"  KCF peak:  ({d2_r:+d}, {d2_c:+d})\n\n"
        f"NCC DISPLACEMENT\n"
        f"  ({ncc_disp_row:+d}, {ncc_disp_col:+d}) = {ncc_dist:.0f} px\n\n"
        f"KCF FINE DISPLACEMENT\n"
        f"  ({d2_r:+d}, {d2_c:+d}) within window"
    )
    fig.text(0.80, 0.50, summary, fontsize=12, color='white',
             ha='center', va='center', fontfamily='monospace',
             bbox=dict(fc='#1a1a1a', ec='white', lw=2, pad=20))

    fig.text(0.50, 0.93,
             f'KCF Displacement Detection  |  '
             f'KCF: ({d2_r:+d}, {d2_c:+d})  |  '
             f'NCC: ({ncc_disp_row:+d}, {ncc_disp_col:+d}) = {ncc_dist:.0f} px',
             fontsize=15, fontweight='bold', color='white',
             ha='center', va='center')

    fig.canvas.draw()
    print(f'\n  >> Step {STEPS}: Final summary. Close the window to exit.')
    plt.show(block=True)


if __name__ == '__main__':
    main()
