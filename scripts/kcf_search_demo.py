"""
kcf_search_demo.py
KCF target detection + displacement measurement on real images.

Pipeline:
  1. NCC full-image search  → find target centre in each image     [CPU/Python]
  2. KCF hardware pipeline  → validate detection on 32x32 patch    [FPGA/Hardware]
  3. Report displacement between target positions across images

Usage:
  python scripts/kcf_search_demo.py \\
      "docs/MidTerm Report/Real_test_1.png" "docs/MidTerm Report/Real_test_2.png" \\
      --target-row 200 --target-col 380
"""

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from mpl_toolkits.mplot3d import Axes3D
import argparse
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR   = os.path.join(SCRIPT_DIR, '..')
sys.path.insert(0, SCRIPT_DIR)

from kcf_real_image import (
    float_to_q88, write_mem, load_image_gray, crop_patch,
    make_hann, make_gaussian_label, train_alpha, detect,
    N, FRAC, SCALE, SIGMA, LAMBDA,
)

DATA_DIR = os.path.join(ROOT_DIR, 'data')
FIG_DIR  = os.path.join(ROOT_DIR, 'docs', 'MidTerm Report')


# ── Full-Image NCC Search ────────────────────────────────────────────────────

def ncc_search(image, target_patch):
    """FFT-based NCC — locate target in full image.
    Returns (ncc_map, top_left_row, top_left_col, centre_row, centre_col, peak_ncc).
    """
    img_H, img_W = image.shape
    t0 = time.time()

    template = target_patch - target_patch.mean()
    t_norm = np.linalg.norm(template)

    t_pad = np.zeros((img_H, img_W))
    t_pad[:N, :N] = template
    T = np.fft.fft2(t_pad)
    I = np.fft.fft2(image)
    corr = np.fft.ifft2(np.conj(T) * I).real

    mask = np.zeros((img_H, img_W)); mask[:N, :N] = 1.0
    M = np.fft.fft2(mask)
    local_sum = np.fft.ifft2(np.conj(M) * I).real
    local_mean = local_sum / (N * N)
    local_sq = np.fft.ifft2(np.conj(M) * np.fft.fft2(image ** 2)).real
    local_var = local_sq / (N * N) - local_mean ** 2
    local_std = np.sqrt(np.maximum(local_var, 1e-10))

    denom = np.maximum(t_norm * N * local_std, 1e-10)
    ncc_map = corr / denom

    elapsed = time.time() - t0

    pk_idx = np.argmax(ncc_map)
    tl_r, tl_c = pk_idx // img_W, pk_idx % img_W
    c_r, c_c = tl_r + N // 2, tl_c + N // 2
    ncc_val = float(ncc_map[tl_r, tl_c])
    print(f'  NCC search ({img_H}x{img_W}): {elapsed*1000:.0f} ms  |  '
          f'centre = ({c_r}, {c_c})  |  NCC = {ncc_val:.4f}')
    return ncc_map, tl_r, tl_c, c_r, c_c, ncc_val


# ── .mem helpers ──────────────────────────────────────────────────────────────

def write_alpha_mem(alpha_hat, X_hat_train):
    combined = np.conj(alpha_hat) * X_hat_train
    K = 1
    while K * 2 * np.max(np.abs(combined)) < 120.0:
        K *= 2
    K = max(K, 1)
    scaled = combined * K
    print(f'  K={K}, max|scaled|={np.max(np.abs(scaled)):.4f}')
    vals = []
    for r in range(N):
        for c in range(N):
            vals.append(float_to_q88(scaled[r, c].real))
            vals.append(float_to_q88(scaled[r, c].imag))
    write_mem('alpha_hat.mem', vals)
    return K


def write_patch_mem(patch, filename='test_patch_32.mem'):
    vals = [float_to_q88(patch[r, c]) for r in range(N) for c in range(N)]
    write_mem(filename, vals)


def write_threshold_mem(q88_val):
    path = os.path.join(DATA_DIR, 'conf_threshold.mem')
    with open(path, 'w') as f:
        f.write(f'{q88_val & 0xFFFF:04x}\n')
    print(f'  Threshold: 0x{q88_val & 0xFFFF:04x} (Q8.8 = {q88_val / SCALE:.4f})')


# ── PSR ───────────────────────────────────────────────────────────────────────

def compute_psr(response, exclude_radius=5):
    pk_idx = np.argmax(response)
    pk_r, pk_c = divmod(pk_idx, N)
    pk_val = response[pk_r, pk_c]
    R, C = np.meshgrid(np.arange(N), np.arange(N), indexing='ij')
    dr = np.minimum(np.abs(R - pk_r), N - np.abs(R - pk_r))
    dc = np.minimum(np.abs(C - pk_c), N - np.abs(C - pk_c))
    side = response[(dr > exclude_radius) | (dc > exclude_radius)]
    if len(side) == 0:
        return 0.0
    return float((pk_val - np.mean(side)) / max(np.std(side), 1e-6))


def signed_disp(raw_r, raw_c):
    dr = raw_r if raw_r < N // 2 else raw_r - N
    dc = raw_c if raw_c < N // 2 else raw_c - N
    return dr, dc


# ── Figures ───────────────────────────────────────────────────────────────────

def fig_detection(test_name, image, ncc_map, tl_r, tl_c, c_r, c_c, ncc_val,
                  kcf_resp, pk_r, pk_c, psr, disp_r, disp_c,
                  train_tl=None):
    """Full figure: image with NCC heatmap + KCF response 2D/3D."""
    os.makedirs(FIG_DIR, exist_ok=True)

    fig = plt.figure(figsize=(18, 6))

    # ── Panel 1: Image + NCC heatmap ──
    ax1 = fig.add_subplot(131)
    ax1.imshow(image, cmap='gray', vmin=0, vmax=1)
    vmax = max(np.percentile(ncc_map, 99.5), 0.8)
    im = ax1.imshow(ncc_map, cmap='jet', alpha=0.45, interpolation='bilinear',
                    vmin=0, vmax=vmax)
    fig.colorbar(im, ax=ax1, label='NCC', shrink=0.7, pad=0.02)

    # Detected box
    rect = Rectangle((tl_c, tl_r), N, N, lw=2.5, edgecolor='lime',
                      facecolor='none', label=f'Detected ({c_r},{c_c})')
    ax1.add_patch(rect)
    ax1.plot(c_c, c_r, 'g+', ms=16, mew=2.5)

    if train_tl is not None:
        tr, tc = train_tl
        rect_t = Rectangle((tc, tr), N, N, lw=2, edgecolor='red',
                            facecolor='none', ls='--', label='Training ROI')
        ax1.add_patch(rect_t)

    ax1.set_title(f'Target centre: ({c_r}, {c_c})\nNCC = {ncc_val:.3f}',
                  fontsize=11, fontweight='bold')
    ax1.legend(loc='upper right', fontsize=8, framealpha=0.8)
    ax1.axis('off')

    # ── Panel 2: KCF 2D response ──
    ax2 = fig.add_subplot(132)
    resp_s = np.fft.fftshift(kcf_resp)
    ext = [-N//2, N//2, N//2, -N//2]
    im2 = ax2.imshow(resp_s, cmap='hot', interpolation='nearest', extent=ext)
    ax2.plot(disp_c, disp_r, 'c*', ms=16, mec='white', mew=1.5)
    ax2.axhline(0, color='white', lw=0.5, alpha=0.4)
    ax2.axvline(0, color='white', lw=0.5, alpha=0.4)
    ax2.set_title(f'KCF Response\nPSR = {psr:.1f}  |  disp = ({disp_r:+d},{disp_c:+d})',
                  fontsize=11, fontweight='bold')
    ax2.set_xlabel('Col displacement')
    ax2.set_ylabel('Row displacement')
    fig.colorbar(im2, ax=ax2, shrink=0.7, pad=0.02)

    # ── Panel 3: KCF 3D surface ──
    ax3 = fig.add_subplot(133, projection='3d')
    rows_ax = np.arange(N) - N//2
    cols_ax = np.arange(N) - N//2
    CC, RR = np.meshgrid(cols_ax, rows_ax)
    ax3.plot_surface(CC, RR, resp_s, cmap='hot', edgecolor='none', alpha=0.9)
    pz = resp_s[N//2 + disp_r, N//2 + disp_c]
    ax3.scatter([disp_c], [disp_r], [pz], c='cyan', s=200, marker='*',
                edgecolors='white', linewidths=1, zorder=5)
    ax3.set_xlabel('Col')
    ax3.set_ylabel('Row')
    ax3.set_zlabel('Response')
    ax3.view_init(elev=35, azim=-50)

    fig.suptitle(f'{test_name}', fontsize=14, fontweight='bold')
    fig.tight_layout(rect=[0, 0, 1, 0.93])
    out = os.path.join(FIG_DIR, f'fig_{test_name}.png')
    fig.savefig(out, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f'  Saved {os.path.basename(out)}')


def fig_displacement_summary(r1, r2, disp_row, disp_col):
    """Summary figure showing both detections and the displacement vector."""
    os.makedirs(FIG_DIR, exist_ok=True)
    fig, axes = plt.subplots(1, 3, figsize=(18, 5.5))

    # ── Panel 1 & 2: both images with detected centres ──
    for ax, res, title in [(axes[0], r1, 'Image 1'), (axes[1], r2, 'Image 2')]:
        ax.imshow(res['image'], cmap='gray', vmin=0, vmax=1)
        ax.imshow(res['ncc_map'], cmap='jet', alpha=0.4, interpolation='bilinear',
                  vmin=0, vmax=max(np.percentile(res['ncc_map'], 99.5), 0.8))
        rect = Rectangle((res['tl_c'], res['tl_r']), N, N, lw=2.5,
                          edgecolor='lime', facecolor='none')
        ax.add_patch(rect)
        ax.plot(res['c_c'], res['c_r'], 'g+', ms=18, mew=3)
        ax.set_title(f'{title}\nTarget centre: ({res["c_r"]}, {res["c_c"]})',
                     fontsize=12, fontweight='bold')
        ax.axis('off')

    # ── Panel 3: displacement info ──
    ax3 = axes[2]
    ax3.set_xlim(-1, 1); ax3.set_ylim(-1, 1)
    ax3.set_aspect('equal')
    ax3.axis('off')

    dist = np.sqrt(disp_row**2 + disp_col**2)
    info = (
        f"NCC coarse:  ({r1['c_r']},{r1['c_c']})  /  ({r2['c_r']},{r2['c_c']})\n"
        f"KCF fine:    ({r1['disp_r']:+d},{r1['disp_c']:+d})  /  ({r2['disp_r']:+d},{r2['disp_c']:+d})\n"
        f"Precise:     ({r1['precise_r']},{r1['precise_c']})  /  ({r2['precise_r']},{r2['precise_c']})\n\n"
        f"Row displacement: {disp_row:+d} px\n"
        f"Col displacement: {disp_col:+d} px\n"
        f"Euclidean distance: {dist:.1f} px\n\n"
        f"HW peak_row: {r1['pk_r']}  /  {r2['pk_r']}\n"
        f"HW peak_col: {r1['pk_c']}  /  {r2['pk_c']}\n"
        f"HW peak_val: {r1['hw_peak']:.4f}  /  {r2['hw_peak']:.4f}"
    )
    ax3.text(0, 0.5, info, transform=ax3.transAxes, fontsize=13,
             verticalalignment='center', fontfamily='monospace',
             bbox=dict(boxstyle='round,pad=0.8', fc='#f0f0f0', ec='gray'))
    ax3.set_title('Displacement', fontsize=12, fontweight='bold')

    fig.suptitle(f'Target Displacement: ({disp_row:+d}, {disp_col:+d}) px  |  '
                 f'distance = {dist:.1f} px',
                 fontsize=14, fontweight='bold')
    fig.tight_layout(rect=[0, 0, 1, 0.90])
    out = os.path.join(FIG_DIR, 'fig_displacement_summary.png')
    fig.savefig(out, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f'  Saved {os.path.basename(out)}')


# ── Core ──────────────────────────────────────────────────────────────────────

def run_detect(test_name, image, target_patch, alpha_hat, X_hat_train,
               hann_1d, K, hw_offset=(0, 0), train_tl=None):
    """Find target in image, extract 32x32 patch with hw_offset, run KCF.

    The NCC coarse search finds the target top-left at (tl_r, tl_c).
    The HW search window is placed at (tl_r + hw_offset[0], tl_c + hw_offset[1]).
    KCF then measures the fine displacement within the 32x32 window.

    Precise target centre = NCC position + KCF displacement.
    """
    ncc_map, tl_r, tl_c, c_r, c_c, ncc_val = ncc_search(image, target_patch)

    # Place HW search window with offset (simulates tracker lag)
    img_H, img_W = image.shape
    off_r, off_c = hw_offset
    r0 = max(0, min(tl_r + off_r, img_H - N))
    c0 = max(0, min(tl_c + off_c, img_W - N))
    patch = image[r0:r0+N, c0:c0+N]
    actual_off_r = r0 - tl_r
    actual_off_c = c0 - tl_c
    print(f'  HW window at ({r0},{c0}) [offset ({actual_off_r:+d},{actual_off_c:+d}) from target]')

    # KCF measures fine displacement within the window
    pk_r, pk_c, kcf_resp, _ = detect(patch, alpha_hat, X_hat_train, hann_1d)
    kcf_peak = kcf_resp[pk_r, pk_c]
    psr = compute_psr(kcf_resp)
    disp_r, disp_c = signed_disp(pk_r, pk_c)
    hw_peak = kcf_peak * K / N

    # Precise target centre = window position + N/2 + KCF displacement
    precise_r = r0 + N // 2 + disp_r
    precise_c = c0 + N // 2 + disp_c

    print(f'  KCF peak: ({pk_r},{pk_c})  disp: ({disp_r:+d},{disp_c:+d})  '
          f'val: {kcf_peak:.4f}  PSR: {psr:.1f}')
    print(f'  Precise centre: ({precise_r}, {precise_c})  '
          f'[NCC: ({c_r},{c_c}) + KCF: ({disp_r:+d},{disp_c:+d})]')
    print(f'  HW peak_val: {hw_peak:.4f} (0x{float_to_q88(hw_peak):04x})')

    fig_detection(test_name, image, ncc_map, tl_r, tl_c, c_r, c_c, ncc_val,
                  kcf_resp, pk_r, pk_c, psr, disp_r, disp_c, train_tl)

    return dict(
        image=image, ncc_map=ncc_map,
        tl_r=tl_r, tl_c=tl_c, c_r=c_r, c_c=c_c, ncc=ncc_val,
        pk_r=pk_r, pk_c=pk_c, disp_r=disp_r, disp_c=disp_c,
        precise_r=precise_r, precise_c=precise_c,
        kcf_peak=kcf_peak, psr=psr, hw_peak=hw_peak, patch=patch,
    )


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='KCF Target Detection + Displacement Measurement')
    parser.add_argument('image1', help='Training + detection image 1')
    parser.add_argument('image2', help='Detection image 2')
    parser.add_argument('--target-row', type=int, required=True,
                        help='Target centre row in image1')
    parser.add_argument('--target-col', type=int, required=True,
                        help='Target centre col in image1')
    parser.add_argument('--hw-offset1', type=int, nargs=2, default=[2, -1],
                        metavar=('DR', 'DC'),
                        help='HW search window offset for image1 (default: 2 -1)')
    parser.add_argument('--hw-offset2', type=int, nargs=2, default=[-2, 3],
                        metavar=('DR', 'DC'),
                        help='HW search window offset for image2 (default: -2 3)')
    args = parser.parse_args()

    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(FIG_DIR, exist_ok=True)

    # ── Load ──
    print(f'\n=== Image 1: {args.image1} ===')
    img1 = load_image_gray(args.image1)
    print(f'  {img1.shape[0]} x {img1.shape[1]}')

    print(f'\n=== Image 2: {args.image2} ===')
    img2 = load_image_gray(args.image2)
    print(f'  {img2.shape[0]} x {img2.shape[1]}')

    # ── Train KCF ──
    target, t_r0, t_c0 = crop_patch(img1, args.target_row, args.target_col)
    print(f'\n=== Training KCF on target [{t_r0},{t_r0+N}) x [{t_c0},{t_c0+N}) ===')
    hann_1d = make_hann()
    alpha_hat, X_hat_train, _ = train_alpha(target, hann_1d)
    K = write_alpha_mem(alpha_hat, X_hat_train)

    # ── Detect in both images ──
    print(f'\n{"="*60}')
    print(f'  DETECTION — Image 1  (HW offset: {args.hw_offset1})')
    print(f'{"="*60}')
    r1 = run_detect('Image_1_detection', img1, target,
                     alpha_hat, X_hat_train, hann_1d, K,
                     hw_offset=tuple(args.hw_offset1),
                     train_tl=(t_r0, t_c0))

    print(f'\n{"="*60}')
    print(f'  DETECTION — Image 2  (HW offset: {args.hw_offset2})')
    print(f'{"="*60}')
    r2 = run_detect('Image_2_detection', img2, target,
                     alpha_hat, X_hat_train, hann_1d, K,
                     hw_offset=tuple(args.hw_offset2))

    # ── Displacement between images (using precise KCF-refined centres) ──
    disp_row = r2['precise_r'] - r1['precise_r']
    disp_col = r2['precise_c'] - r1['precise_c']
    dist = np.sqrt(disp_row**2 + disp_col**2)

    print(f'\n{"="*60}')
    print(f'  TARGET DISPLACEMENT')
    print(f'{"="*60}')
    print(f'  Image 1 target centre: ({r1["c_r"]}, {r1["c_c"]})')
    print(f'  Image 2 target centre: ({r2["c_r"]}, {r2["c_c"]})')
    print(f'  Row displacement:  {disp_row:+d} px')
    print(f'  Col displacement:  {disp_col:+d} px')
    print(f'  Euclidean distance: {dist:.1f} px')

    # ── Write .mem files ──
    print(f'\n=== Writing .mem files ===')
    write_patch_mem(r1['patch'], 'test_patch_32.mem')
    write_patch_mem(r2['patch'], 'test2_patch_32.mem')
    hw_thresh = min(r1['hw_peak'], r2['hw_peak']) * 0.5
    hw_thresh_q88 = max(1, int(round(hw_thresh * SCALE)))
    write_threshold_mem(hw_thresh_q88)

    # Summary figure
    fig_displacement_summary(r1, r2, disp_row, disp_col)

    # ── Final summary ──
    print(f'\n{"="*60}')
    print(f'  SUMMARY')
    print(f'{"="*60}')
    print(f'  {"":>10} {"NCC centre":>14} {"KCF disp":>12} {"Precise":>14} '
          f'{"peak_val":>10}')
    print(f'  {"-"*10} {"-"*14} {"-"*12} {"-"*14} {"-"*10}')
    print(f'  {"Image 1":>10} '
          f'{"(%d,%d)" % (r1["c_r"],r1["c_c"]):>14} '
          f'{"(%+d,%+d)" % (r1["disp_r"],r1["disp_c"]):>12} '
          f'{"(%d,%d)" % (r1["precise_r"],r1["precise_c"]):>14} '
          f'{r1["kcf_peak"]:>10.4f}')
    print(f'  {"Image 2":>10} '
          f'{"(%d,%d)" % (r2["c_r"],r2["c_c"]):>14} '
          f'{"(%+d,%+d)" % (r2["disp_r"],r2["disp_c"]):>12} '
          f'{"(%d,%d)" % (r2["precise_r"],r2["precise_c"]):>14} '
          f'{r2["kcf_peak"]:>10.4f}')
    print(f'\n  Displacement: ({disp_row:+d}, {disp_col:+d}) px  '
          f'= {dist:.1f} px')
    print(f'{"="*60}')

    print(f'\n  Verilog .mem files:')
    print(f'    data/test_patch_32.mem   — Image 1 (expect peak_row={r1["pk_r"]}, peak_col={r1["pk_c"]})')
    print(f'    data/test2_patch_32.mem  — Image 2 (expect peak_row={r2["pk_r"]}, peak_col={r2["pk_c"]})')
    print(f'\n  To run Image 2 in Verilog:')
    print(f'    copy data\\test2_patch_32.mem data\\test_patch_32.mem')


if __name__ == '__main__':
    main()
