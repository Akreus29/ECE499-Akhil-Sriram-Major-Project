"""
kcf_search_demo.py
KCF sliding-window search + confidence demo.

Demonstrates two scenarios:
  Test 1 (Target Found):    Train on 32x32 crop, search same image → high confidence
  Test 2 (Target Not Found): Same filter, search different image  → low confidence

Confidence metric: normalised peak ratio = peak_val / self_peak,
where self_peak is the response peak when detecting the target against itself.
This gives a [0, 1] score: 1.0 = perfect match, ~0 = no match.

Generates:
  - data/alpha_hat.mem        (trained combined filter)
  - data/test_patch_32.mem    (search patch for Verilog)
  - data/conf_threshold.mem   (Q8.8 confidence threshold)
  - docs/MidTerm Report/fig_test*.png  (visualisation figures)

Usage:
  python scripts/kcf_search_demo.py --both data/Test_image1.png data/test_image.png \\
      --target-row 130 --target-col 170
  python scripts/kcf_search_demo.py --test1 data/Test_image1.png \\
      --target-row 130 --target-col 170
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

# ── Add parent of scripts/ so we can import from kcf_real_image ──────────────
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

# Default confidence threshold (normalised peak ratio)
DEFAULT_CONF_THRESHOLD = 0.4

# Higher regularisation for detection mode (vs LAMBDA=0.01 for tracking).
# This prevents the filter from amplifying noise at low-energy frequencies,
# which is critical for sliding-window detection where we need to reject
# non-matching patches rather than just track small displacements.
LAMBDA_DETECT = 1.0


# ── Detection-mode KCF (higher lambda) ────────────────────────────────────────

def train_alpha_detect(target_patch, hann_1d):
    """Train KCF filter with high regularisation for detection mode."""
    hann_2d = np.outer(hann_1d, hann_1d)
    windowed = target_patch * hann_2d
    X_hat = np.fft.fft2(windowed)
    Y_hat = np.fft.fft2(make_gaussian_label())
    K_hat = np.conj(X_hat) * X_hat
    alpha_hat = Y_hat / (K_hat + LAMBDA_DETECT)
    return alpha_hat, X_hat, windowed


def detect_centre(search_patch, alpha_hat, X_hat_train, hann_1d):
    """Run KCF detection, return response[0,0] and full response."""
    hann_2d = np.outer(hann_1d, hann_1d)
    windowed = search_patch * hann_2d
    Z_hat = np.fft.fft2(windowed)
    K_xz = np.conj(X_hat_train) * Z_hat
    response = np.fft.ifft2(K_xz * alpha_hat).real
    pk = np.unravel_index(np.argmax(response), (N, N))
    return response[0, 0], pk[0], pk[1], response


# ── Confidence Metric ────────────────────────────────────────────────────────

def compute_psr(response, exclude_radius=5):
    """Peak-to-Sidelobe Ratio (secondary metric, for display only)."""
    peak_idx = np.argmax(response)
    peak_r, peak_c = divmod(peak_idx, N)
    peak_val = response[peak_r, peak_c]

    rows, cols = np.arange(N), np.arange(N)
    R, C = np.meshgrid(rows, cols, indexing='ij')
    dr = np.minimum(np.abs(R - peak_r), N - np.abs(R - peak_r))
    dc = np.minimum(np.abs(C - peak_c), N - np.abs(C - peak_c))
    sidelobe_mask = (dr > exclude_radius) | (dc > exclude_radius)

    sidelobe = response[sidelobe_mask]
    if len(sidelobe) == 0:
        return 0.0
    mean_sl = np.mean(sidelobe)
    std_sl  = max(np.std(sidelobe), 1e-6)
    return float((peak_val - mean_sl) / std_sl)


# ── Sliding Window Search ────────────────────────────────────────────────────

def cosine_confidence(response, gauss_label):
    """Cosine similarity between response and ideal Gaussian label.

    Measures how Gaussian-shaped the response is, regardless of magnitude.
    For matching patches: response ≈ Gaussian → cosine → 1.0
    For non-matching:     response ≈ noise    → cosine → ~0
    """
    r_flat = response.ravel()
    g_flat = gauss_label.ravel()
    dot = np.dot(r_flat, g_flat)
    norm_r = np.linalg.norm(r_flat)
    norm_g = np.linalg.norm(g_flat)
    if norm_r < 1e-10:
        return 0.0
    return float(dot / (norm_r * norm_g))


def sliding_window_search(image, alpha_hat, X_hat_train, hann_1d,
                          self_peak, stride=4):
    """Slide a 32x32 window, compute cosine confidence.

    confidence = cosine_similarity(response, gaussian_label)
    This measures how Gaussian-shaped the response map is.
    1.0 = perfect match (response is a clean Gaussian), ~0 = no match.

    Returns:
        conf_map:  2D array of confidence values
        best:      dict for highest-confidence window
        worst:     dict for lowest-confidence window
    """
    H, W = image.shape
    n_rows = (H - N) // stride + 1
    n_cols = (W - N) // stride + 1
    total  = n_rows * n_cols

    gauss_label = make_gaussian_label()

    conf_map = np.zeros((n_rows, n_cols))
    best  = {'conf': -np.inf}
    worst = {'conf':  np.inf}

    print(f'  Sliding window: {n_rows}x{n_cols} = {total} positions (stride={stride})')
    t0 = time.time()

    for ir in range(n_rows):
        r0 = ir * stride
        for ic in range(n_cols):
            c0 = ic * stride
            patch = image[r0:r0+N, c0:c0+N]

            centre_val, pk_r, pk_c, response = detect_centre(
                patch, alpha_hat, X_hat_train, hann_1d)
            conf = cosine_confidence(response, gauss_label)
            psr  = compute_psr(response)
            peak_val = response[pk_r, pk_c]

            conf_map[ir, ic] = conf

            info = dict(conf=conf, psr=psr, peak_val=peak_val,
                        centre_val=centre_val,
                        response=response.copy(), patch=patch.copy(),
                        r0=r0, c0=c0, peak_r=pk_r, peak_c=pk_c)
            if conf > best['conf']:
                best = info
            if conf < worst['conf']:
                worst = info

        if (ir + 1) % 20 == 0 or ir == n_rows - 1:
            elapsed = time.time() - t0
            pct = (ir + 1) / n_rows * 100
            print(f'    {pct:5.1f}%  ({ir+1}/{n_rows} rows, {elapsed:.1f}s)')

    elapsed = time.time() - t0
    print(f'  Search complete in {elapsed:.1f}s')
    return conf_map, best, worst, stride


# ── .mem File Generation ─────────────────────────────────────────────────────

def write_alpha_mem(alpha_hat, X_hat_train):
    """Write combined filter to alpha_hat.mem. Returns adaptive K."""
    combined = np.conj(alpha_hat) * X_hat_train
    max_combined = np.max(np.abs(combined))

    K = 1
    while K * 2 * max_combined < 120.0:
        K *= 2
    if K < 1:
        K = 1

    combined_scaled = combined * K
    print(f'  Combined filter: K={K}, max|combined*K|={np.max(np.abs(combined_scaled)):.4f}')

    values = []
    for r in range(N):
        for c in range(N):
            values.append(float_to_q88(combined_scaled[r, c].real))
            values.append(float_to_q88(combined_scaled[r, c].imag))
    write_mem('alpha_hat.mem', values)
    return K


def write_patch_mem(patch):
    """Write a 32x32 search patch to test_patch_32.mem."""
    values = [float_to_q88(patch[r, c]) for r in range(N) for c in range(N)]
    write_mem('test_patch_32.mem', values)


def write_threshold_mem(threshold_q88):
    """Write a single Q8.8 threshold value to conf_threshold.mem."""
    path = os.path.join(DATA_DIR, 'conf_threshold.mem')
    with open(path, 'w') as f:
        f.write(f'{threshold_q88 & 0xFFFF:04x}\n')
    print(f'  Written threshold 0x{threshold_q88 & 0xFFFF:04x} '
          f'(Q8.8 = {threshold_q88 / SCALE:.4f}) to {path}')


# ── Figure Generation ────────────────────────────────────────────────────────

def generate_search_figures(test_name, image, conf_map, stride, best, worst,
                            conf_threshold, target_r0=None, target_c0=None):
    """Generate heatmap + response figures for one test."""
    os.makedirs(FIG_DIR, exist_ok=True)
    H, W = image.shape

    # ── Confidence heatmap overlay on image ──
    fig, ax = plt.subplots(figsize=(12, 7))
    ax.imshow(image, cmap='gray', vmin=0, vmax=1)

    n_rows, n_cols = conf_map.shape
    heatmap_extent = [0, (n_cols - 1) * stride + N, (n_rows - 1) * stride + N, 0]
    im = ax.imshow(conf_map, cmap='jet', alpha=0.45, interpolation='bilinear',
                   extent=heatmap_extent, vmin=0, vmax=max(conf_map.max(), 1.0))
    fig.colorbar(im, ax=ax, label='Confidence (peak / self_peak)', shrink=0.8)

    if target_r0 is not None and target_c0 is not None:
        rect_t = Rectangle((target_c0, target_r0), N, N, lw=2.5,
                            edgecolor='red', facecolor='none', linestyle='--',
                            label='Target (training)')
        ax.add_patch(rect_t)

    found = best['conf'] > conf_threshold
    if found:
        rect_b = Rectangle((best['c0'], best['r0']), N, N, lw=3,
                            edgecolor='lime', facecolor='none',
                            label=f'Best match (conf={best["conf"]:.2f})')
        ax.add_patch(rect_b)
        ax.plot(best['c0'] + N // 2, best['r0'] + N // 2, '*',
                color='lime', markersize=20, markeredgecolor='white', markeredgewidth=1)

    verdict = 'TARGET FOUND' if found else 'TARGET NOT FOUND'
    colour = 'lime' if found else 'red'
    ax.set_title(f'{test_name}: {verdict}  (best conf = {best["conf"]:.3f}, '
                 f'threshold = {conf_threshold:.2f})',
                 fontsize=14, fontweight='bold', color=colour)
    ax.legend(loc='upper right', fontsize=10, framealpha=0.8)
    ax.axis('off')
    fig.savefig(os.path.join(FIG_DIR, f'fig_{test_name}_search_heatmap.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f'  Saved fig_{test_name}_search_heatmap.png')

    # ── Response map at best position ──
    resp = best['response']
    resp_shifted = np.fft.fftshift(resp)

    pk_r, pk_c = best['peak_r'], best['peak_c']
    dy = pk_r if pk_r < N // 2 else pk_r - N
    dx = pk_c if pk_c < N // 2 else pk_c - N

    fig = plt.figure(figsize=(14, 5))

    # 2D heatmap
    ax1 = fig.add_subplot(121)
    extent = [-N//2, N//2, N//2, -N//2]
    im0 = ax1.imshow(resp_shifted, cmap='hot', interpolation='nearest', extent=extent)
    ax1.plot(dx, dy, 'c*', markersize=18, markeredgecolor='white', markeredgewidth=1.5)
    ax1.axhline(0, color='white', lw=0.5, alpha=0.4)
    ax1.axvline(0, color='white', lw=0.5, alpha=0.4)
    ax1.set_title(f'Response Map — conf = {best["conf"]:.3f}, PSR = {best["psr"]:.1f}',
                  fontsize=12, fontweight='bold')
    ax1.set_xlabel('Column displacement')
    ax1.set_ylabel('Row displacement')
    fig.colorbar(im0, ax=ax1, shrink=0.8)

    # 3D surface
    ax3 = fig.add_subplot(122, projection='3d')
    rows_ax = np.arange(N) - N // 2
    cols_ax = np.arange(N) - N // 2
    CC, RR = np.meshgrid(cols_ax, rows_ax)
    ax3.plot_surface(CC, RR, resp_shifted, cmap='hot', edgecolor='none', alpha=0.9)
    peak_z = resp_shifted[N // 2 + dy, N // 2 + dx]
    ax3.scatter([dx], [dy], [peak_z], color='cyan', s=200, marker='*',
                edgecolors='white', linewidths=1, zorder=5)
    ax3.plot([dx, dx], [dy, dy], [0, peak_z], color='cyan', lw=2, ls='--')
    ax3.set_xlabel('Col disp.')
    ax3.set_ylabel('Row disp.')
    ax3.set_zlabel('Response')
    ax3.set_title(f'Peak = {best["peak_val"]:.4f}', fontsize=11)
    ax3.view_init(elev=35, azim=-50)

    fig.suptitle(f'{test_name}: Detection Response at Best Window '
                 f'(row={best["r0"]}, col={best["c0"]})',
                 fontsize=13, fontweight='bold')
    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(os.path.join(FIG_DIR, f'fig_{test_name}_response.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f'  Saved fig_{test_name}_response.png')


def generate_comparison_figure(best1, best2, conf_threshold):
    """Side-by-side comparison of Test 1 vs Test 2 responses."""
    os.makedirs(FIG_DIR, exist_ok=True)

    fig, axes = plt.subplots(1, 3, figsize=(18, 5))

    for i, (info, title, colour) in enumerate([
        (best1, 'Test 1: Target Present', 'lime'),
        (best2, 'Test 2: Target Absent', 'red'),
    ]):
        resp_shifted = np.fft.fftshift(info['response'])
        extent = [-N//2, N//2, N//2, -N//2]
        im = axes[i].imshow(resp_shifted, cmap='hot', interpolation='nearest', extent=extent)
        fig.colorbar(im, ax=axes[i], shrink=0.8)

        pk_r, pk_c = info['peak_r'], info['peak_c']
        dy = pk_r if pk_r < N // 2 else pk_r - N
        dx = pk_c if pk_c < N // 2 else pk_c - N
        axes[i].plot(dx, dy, 'c*', markersize=16, markeredgecolor='white', markeredgewidth=1.5)
        axes[i].axhline(0, color='white', lw=0.5, alpha=0.4)
        axes[i].axvline(0, color='white', lw=0.5, alpha=0.4)

        found = info['conf'] > conf_threshold
        verdict = 'FOUND' if found else 'NOT FOUND'
        axes[i].set_title(f'{title}\nConf = {info["conf"]:.3f}  →  {verdict}',
                          fontsize=12, fontweight='bold', color=colour)
        axes[i].set_xlabel('Column displacement')
        axes[i].set_ylabel('Row displacement')

    # Bar chart showing confidence comparison
    labels = ['Test 1\n(target present)', 'Test 2\n(target absent)']
    confs = [best1['conf'], best2['conf']]
    colors = ['lime', 'red']
    bars = axes[2].bar(labels, confs, color=colors, edgecolor='white', linewidth=1.5, width=0.5)
    axes[2].axhline(conf_threshold, color='yellow', ls='--', lw=2,
                     label=f'Threshold = {conf_threshold:.2f}')
    axes[2].set_ylabel('Confidence (peak / self_peak)', fontsize=11)
    axes[2].set_title('Confidence Score', fontsize=12, fontweight='bold')
    axes[2].legend(fontsize=10)
    axes[2].set_ylim(0, max(confs) * 1.3)
    for bar, c in zip(bars, confs):
        axes[2].text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.02,
                     f'{c:.3f}', ha='center', fontsize=12, fontweight='bold')

    fig.suptitle(f'Confidence Comparison (threshold = {conf_threshold:.2f})',
                 fontsize=14, fontweight='bold')
    fig.tight_layout(rect=[0, 0, 1, 0.92])
    fig.savefig(os.path.join(FIG_DIR, 'fig_confidence_comparison.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_confidence_comparison.png')


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='KCF Search + Confidence Demo',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  # Run both tests (recommended):
  python scripts/kcf_search_demo.py --both data/Test_image1.png data/test_image.png \\
      --target-row 130 --target-col 170

  # Test 1 only:
  python scripts/kcf_search_demo.py --test1 data/Test_image1.png \\
      --target-row 130 --target-col 170
""")
    parser.add_argument('--test1', metavar='IMAGE', help='Run Test 1: search same image')
    parser.add_argument('--test2', nargs=2, metavar=('TRAIN_IMG', 'SEARCH_IMG'),
                        help='Run Test 2: train on img1, search img2')
    parser.add_argument('--both', nargs=2, metavar=('TRAIN_IMG', 'SEARCH_IMG'),
                        help='Run both tests')
    parser.add_argument('--target-row', type=int, required=True, help='Target centre row')
    parser.add_argument('--target-col', type=int, required=True, help='Target centre col')
    parser.add_argument('--stride', type=int, default=4, help='Sliding window stride (default 4)')
    parser.add_argument('--conf-threshold', type=float, default=DEFAULT_CONF_THRESHOLD,
                        help=f'Confidence threshold (default {DEFAULT_CONF_THRESHOLD})')
    args = parser.parse_args()

    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(FIG_DIR, exist_ok=True)

    run_test1 = args.test1 is not None or args.both is not None
    run_test2 = args.test2 is not None or args.both is not None

    if not run_test1 and not run_test2:
        parser.error('Specify --test1, --test2, or --both')

    # Resolve image paths
    search2_img_path = None
    if args.both:
        train_img_path   = args.both[0]
        search2_img_path = args.both[1]
    elif args.test1:
        train_img_path = args.test1
    elif args.test2:
        train_img_path   = args.test2[0]
        search2_img_path = args.test2[1]

    # ── Load training image and crop target ──
    print(f'\n=== Loading training image: {train_img_path} ===')
    train_image = load_image_gray(train_img_path)
    print(f'  Image size: {train_image.shape[0]}x{train_image.shape[1]}')

    target_patch, t_r0, t_c0 = crop_patch(train_image, args.target_row, args.target_col)
    print(f'  Target patch: rows [{t_r0}, {t_r0+N}), cols [{t_c0}, {t_c0+N})')
    print(f'  Patch intensity: [{target_patch.min():.3f}, {target_patch.max():.3f}]')

    # ── Train KCF filter ──
    # Two filters: high-lambda for detection (Python search), low-lambda for hardware .mem
    print(f'\n=== Training KCF filter ===')
    hann_1d = make_hann()

    # Detection filter (high regularisation — suppresses noise, selective)
    alpha_det, X_hat_det, windowed_target = train_alpha_detect(target_patch, hann_1d)
    print(f'  Detection filter: lambda = {LAMBDA_DETECT}')

    # Hardware filter (low regularisation — standard KCF tracking)
    alpha_hw, X_hat_hw, _ = train_alpha(target_patch, hann_1d)
    K = write_alpha_mem(alpha_hw, X_hat_hw)
    print(f'  Hardware filter:  lambda = {LAMBDA}, K = {K}')

    # ── Self-detection: establish baseline ──
    print(f'\n=== Self-detection (baseline) ===')
    self_centre, self_pk_r, self_pk_c, self_response = detect_centre(
        target_patch, alpha_det, X_hat_det, hann_1d)
    self_peak = self_centre
    gauss_label = make_gaussian_label()
    self_cosine = cosine_confidence(self_response, gauss_label)
    self_psr    = compute_psr(self_response)
    print(f'  Self-detection response[0,0]: {self_peak:.6f}')
    print(f'  Self-detection cosine sim:    {self_cosine:.6f}')
    print(f'  Self-detection PSR:           {self_psr:.2f}')
    print(f'  Confidence = cosine_similarity(response, gaussian_label)')

    # Use detection filter for sliding window search
    alpha_hat   = alpha_det
    X_hat_train = X_hat_det

    # ── Test 1: Search same image ──
    best1, best2 = None, None

    if run_test1:
        print(f'\n{"="*60}')
        print(f'=== TEST 1: Target Present (searching training image) ===')
        print(f'{"="*60}')

        conf_map1, best1, worst1, s1 = sliding_window_search(
            train_image, alpha_hat, X_hat_train, hann_1d,
            self_peak, stride=args.stride)

        found1 = best1['conf'] > args.conf_threshold
        print(f'\n  Best  conf = {best1["conf"]:.4f} (PSR={best1["psr"]:.1f}) '
              f'at ({best1["r0"]}, {best1["c0"]})')
        print(f'  Worst conf = {worst1["conf"]:.4f} at ({worst1["r0"]}, {worst1["c0"]})')
        print(f'  Threshold  = {args.conf_threshold:.2f}')
        print(f'  Result: {">>> TARGET FOUND <<<" if found1 else "TARGET NOT FOUND"}')

        # Write .mem files for Test 1
        print(f'\n  Writing Test 1 .mem files (best-match window)...')
        write_patch_mem(best1['patch'])

        # Compute HW expected peak using the hardware (low-lambda) filter
        _, _, _, hw_resp1 = detect_centre(best1['patch'], alpha_hw, X_hat_hw, hann_1d)
        hw_peak1_raw = np.max(hw_resp1) * K / N
        print(f'  Expected HW peak_val: {hw_peak1_raw:.4f} '
              f'(Q8.8 raw = 0x{float_to_q88(hw_peak1_raw):04x})')

        print(f'\n  Generating Test 1 figures...')
        generate_search_figures('test1', train_image, conf_map1, args.stride,
                                best1, worst1, args.conf_threshold, t_r0, t_c0)

    # ── Test 2: Search different image ──
    if run_test2:
        print(f'\n{"="*60}')
        print(f'=== TEST 2: Target Absent (searching different image) ===')
        print(f'{"="*60}')
        print(f'  Loading search image: {search2_img_path}')
        search_img2 = load_image_gray(search2_img_path)
        print(f'  Image size: {search_img2.shape[0]}x{search_img2.shape[1]}')

        conf_map2, best2, worst2, s2 = sliding_window_search(
            search_img2, alpha_hat, X_hat_train, hann_1d,
            self_peak, stride=args.stride)

        found2 = best2['conf'] > args.conf_threshold
        print(f'\n  Best  conf = {best2["conf"]:.4f} (PSR={best2["psr"]:.1f}) '
              f'at ({best2["r0"]}, {best2["c0"]})')
        print(f'  Worst conf = {worst2["conf"]:.4f} at ({worst2["r0"]}, {worst2["c0"]})')
        print(f'  Threshold  = {args.conf_threshold:.2f}')
        print(f'  Result: {"TARGET FOUND (unexpected!)" if found2 else ">>> TARGET NOT FOUND <<<"}')

        print(f'\n  Writing Test 2 .mem files...')
        write_patch_mem(best2['patch'])

        _, _, _, hw_resp2 = detect_centre(best2['patch'], alpha_hw, X_hat_hw, hann_1d)
        hw_peak2_raw = np.max(hw_resp2) * K / N
        print(f'  Expected HW peak_val: {hw_peak2_raw:.4f} '
              f'(Q8.8 raw = 0x{float_to_q88(hw_peak2_raw):04x})')

        print(f'\n  Generating Test 2 figures...')
        generate_search_figures('test2', search_img2, conf_map2, args.stride,
                                best2, worst2, args.conf_threshold)

    # ── Hardware confidence threshold ──
    if best1 is not None and best2 is not None:
        _, _, _, hr1 = detect_centre(best1['patch'], alpha_hw, X_hat_hw, hann_1d)
        _, _, _, hr2 = detect_centre(best2['patch'], alpha_hw, X_hat_hw, hann_1d)
        hw_p1 = np.max(hr1) * K / N
        hw_p2 = np.max(hr2) * K / N
        hw_thresh = (hw_p1 + hw_p2) / 2.0
        hw_thresh_q88 = int(round(hw_thresh * SCALE))
        hw_thresh_q88 = max(1, min(32767, hw_thresh_q88))
        print(f'\n  HW threshold calibration: test1_peak={hw_p1:.4f}, '
              f'test2_peak={hw_p2:.4f}, threshold={hw_thresh:.4f}')
    elif best1 is not None:
        _, _, _, hr1 = detect_centre(best1['patch'], alpha_hw, X_hat_hw, hann_1d)
        hw_p1 = np.max(hr1) * K / N
        hw_thresh_q88 = int(round(hw_p1 * 0.3 * SCALE))
        hw_thresh_q88 = max(1, min(32767, hw_thresh_q88))
    else:
        hw_thresh_q88 = 0x0020

    write_threshold_mem(hw_thresh_q88)

    # ── Comparison figure ──
    if best1 is not None and best2 is not None:
        print(f'\n  Generating comparison figure...')
        generate_comparison_figure(best1, best2, args.conf_threshold)

    # ── Summary ──
    print(f'\n{"="*60}')
    print(f'  SUMMARY')
    print(f'{"="*60}')
    print(f'  {"Test":<8} {"Image":<20} {"Confidence":>12} {"Threshold":>10} {"Result":>14}')
    print(f'  {"-"*8} {"-"*20} {"-"*12} {"-"*10} {"-"*14}')
    if best1 is not None:
        v1 = 'FOUND' if best1['conf'] > args.conf_threshold else 'NOT FOUND'
        img1_name = os.path.basename(train_img_path)
        print(f'  {"Test1":<8} {img1_name:<20} {best1["conf"]:>12.4f} '
              f'{args.conf_threshold:>10.2f} {v1:>14}')
    if best2 is not None:
        v2 = 'FOUND' if best2['conf'] > args.conf_threshold else 'NOT FOUND'
        img2_name = os.path.basename(search2_img_path)
        print(f'  {"Test2":<8} {img2_name:<20} {best2["conf"]:>12.4f} '
              f'{args.conf_threshold:>10.2f} {v2:>14}')
    print(f'{"="*60}')
    print(f'\n  .mem files written to data/')
    print(f'  Figures saved to docs/MidTerm Report/')
    print(f'  NOTE: test_patch_32.mem contains the LAST test written.')
    print(f'        For Test 1 Verilog sim, re-run with --test1 flag.')


if __name__ == '__main__':
    main()
