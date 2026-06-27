"""
kcf_real_image.py
Real-image KCF detection demo for mid-project presentation.

Flow:
  Frame 1: Load image, crop 32x32 target → train alpha_hat
  Frame 2: Load image, crop 32x32 search patch → detect target → show result

Generates:
  - data/alpha_hat.mem          (trained filter, overwrites synthetic)
  - data/test_patch_32.mem      (search patch from frame 2, overwrites synthetic)
  - docs/MidTerm Report/fig_*   (figures for report/presentation)

Usage:
  python scripts/kcf_real_image.py                                  # synthetic demo frames
  python scripts/kcf_real_image.py frame1.jpg frame2.jpg            # real images
  python scripts/kcf_real_image.py frame1.jpg frame2.jpg --row 80 --col 100
"""

import numpy as np
import matplotlib
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import argparse
import os
import sys

# ── Constants ────────────────────────────────────────────────────────────────
N = 32
FRAC = 8
SCALE = 1 << FRAC  # 256
SIGMA = 2.0
LAMBDA = 1e-2
K_PRESCALE = 16  # alpha pre-scaling factor

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.join(SCRIPT_DIR, '..')
DATA_DIR = os.path.join(ROOT_DIR, 'data')
FIG_DIR = os.path.join(ROOT_DIR, 'docs', 'MidTerm Report')


# ── Utilities ────────────────────────────────────────────────────────────────

def float_to_q88(val):
    """Float → Q8.8 signed 16-bit (unsigned representation for hex)."""
    q = int(round(val * SCALE))
    q = max(-32768, min(32767, q))
    return q & 0xFFFF


def write_mem(filename, values):
    """Write list of 16-bit hex values to .mem file."""
    path = os.path.join(DATA_DIR, filename)
    with open(path, 'w') as f:
        for v in values:
            f.write(f'{v:04x}\n')
    print(f'  Written {len(values)} entries to {path}')


def load_image_gray(path):
    """Load image as grayscale float [0, 1]."""
    try:
        from PIL import Image
        img = Image.open(path).convert('L')
        return np.array(img, dtype=np.float64) / 255.0
    except ImportError:
        import cv2
        img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        if img is None:
            raise FileNotFoundError(f"Cannot load image: {path}")
        return img.astype(np.float64) / 255.0


def crop_patch(frame, center_row, center_col):
    """Extract N×N patch centred at (center_row, center_col). Clamps at edges."""
    h, w = frame.shape
    r0 = max(0, center_row - N // 2)
    c0 = max(0, center_col - N // 2)
    # Adjust if we hit the bottom/right edge
    if r0 + N > h:
        r0 = h - N
    if c0 + N > w:
        c0 = w - N
    r0 = max(0, r0)
    c0 = max(0, c0)
    patch = frame[r0:r0+N, c0:c0+N]
    # Pad if image is smaller than N×N
    if patch.shape != (N, N):
        padded = np.zeros((N, N))
        padded[:patch.shape[0], :patch.shape[1]] = patch
        patch = padded
    return patch, r0, c0


# ── Interactive target selection ─────────────────────────────────────────────

def select_target(frame):
    """Show frame and let user click the target centre. Returns (row, col)."""
    coords = []

    fig, ax = plt.subplots(1, 1, figsize=(8, 8))
    ax.imshow(frame, cmap='gray', vmin=0, vmax=1)
    ax.set_title('Click the CENTER of the target to track, then close the window', fontsize=12)
    ax.axis('off')

    # Draw the 32×32 box preview as user moves mouse
    preview_rect = Rectangle((0, 0), N, N, linewidth=2,
                              edgecolor='red', facecolor='none', linestyle='--')
    ax.add_patch(preview_rect)
    preview_rect.set_visible(False)

    def on_move(event):
        if event.inaxes != ax:
            preview_rect.set_visible(False)
            fig.canvas.draw_idle()
            return
        c, r = int(event.xdata), int(event.ydata)
        preview_rect.set_xy((c - N // 2, r - N // 2))
        preview_rect.set_visible(True)
        fig.canvas.draw_idle()

    def on_click(event):
        if event.inaxes != ax or event.button != 1:
            return
        col, row = int(event.xdata), int(event.ydata)
        coords.append((row, col))
        # Draw confirmed box
        rect = Rectangle((col - N // 2, row - N // 2), N, N,
                          linewidth=2, edgecolor='lime', facecolor='none')
        ax.add_patch(rect)
        ax.plot(col, row, 'r+', markersize=15, markeredgewidth=2)
        ax.set_title(f'Target selected at ({row}, {col}) — close window to continue', fontsize=12)
        fig.canvas.draw()

    fig.canvas.mpl_connect('motion_notify_event', on_move)
    fig.canvas.mpl_connect('button_press_event', on_click)
    plt.show()

    if not coords:
        print('  No target selected! Using image centre.')
        h, w = frame.shape
        return h // 2, w // 2

    # Use the last click
    row, col = coords[-1]
    print(f'  Target selected at: row={row}, col={col}')
    return row, col


# ── Generate synthetic demo frames ──────────────────────────────────────────

def generate_synthetic_frames():
    """Create two 128×128 frames with a bright square that moves."""
    H, W = 128, 128
    np.random.seed(42)  # reproducible
    background = np.random.rand(H, W) * 0.15 + 0.05  # shared background

    # Frame 1: bright 16×16 square centred at (48, 48)
    frame1 = background.copy()
    frame1[40:56, 40:56] = 0.85

    # Frame 2: same object shifted by (+4, +6) → centred at (52, 54)
    frame2 = background.copy()
    frame2[44:60, 46:62] = 0.85

    target_row, target_col = 48, 48  # centre of target in frame 1
    return frame1, frame2, target_row, target_col


# ── KCF Training ─────────────────────────────────────────────────────────────

def make_hann():
    """1D Hann window of length N."""
    return np.array([0.5 * (1 - np.cos(2 * np.pi * n / (N - 1))) for n in range(N)])


def make_gaussian_label():
    """DFT-centred Gaussian desired response."""
    y = np.zeros((N, N))
    for r in range(N):
        for c in range(N):
            dr = min(r, N - r)
            dc = min(c, N - c)
            y[r, c] = np.exp(-(dr**2 + dc**2) / (2 * SIGMA**2))
    return y


def train_alpha(target_patch, hann_1d):
    """Train KCF filter on target patch.
    Returns alpha_hat, X_hat (training spectrum), and windowed patch."""
    hann_2d = np.outer(hann_1d, hann_1d)
    windowed = target_patch * hann_2d

    X_hat = np.fft.fft2(windowed)
    Y_hat = np.fft.fft2(make_gaussian_label())

    # Linear kernel: K_hat = |X_hat|^2
    K_hat = np.conj(X_hat) * X_hat
    alpha_hat = Y_hat / (K_hat + LAMBDA)
    return alpha_hat, X_hat, windowed


def detect(search_patch, alpha_hat, X_hat_train, hann_1d):
    """Run detection using correct KCF formula.
    response = IFFT( conj(X_train) * Z_hat * alpha_hat )
    Returns (peak_row, peak_col, response_map, windowed_search)."""
    hann_2d = np.outer(hann_1d, hann_1d)
    windowed = search_patch * hann_2d

    Z_hat = np.fft.fft2(windowed)
    # Correct KCF: K_xz * alpha = conj(X_train) * Z * alpha
    K_xz = np.conj(X_hat_train) * Z_hat
    response = np.fft.ifft2(K_xz * alpha_hat).real

    peak = np.unravel_index(np.argmax(response), (N, N))
    return peak[0], peak[1], response, windowed


# ── Figure Generation ────────────────────────────────────────────────────────

def generate_figures(frame1, frame2, target_r0, target_c0,
                     search_r0, search_c0, target_patch, search_patch,
                     windowed_target, windowed_search,
                     response, peak_row, peak_col):
    """Generate all presentation figures."""
    matplotlib.use('Agg')  # non-interactive for saving
    os.makedirs(FIG_DIR, exist_ok=True)

    # Convert DFT peak index to displacement (handles circular wrapping)
    dy = peak_row if peak_row < N // 2 else peak_row - N
    dx = peak_col if peak_col < N // 2 else peak_col - N

    # ── Figure 1: Frame 1 with target box ──
    fig, ax = plt.subplots(1, 1, figsize=(6, 6))
    ax.imshow(frame1, cmap='gray', vmin=0, vmax=1)
    rect = Rectangle((target_c0, target_r0), N, N,
                      linewidth=2, edgecolor='red', facecolor='none', label='Target')
    ax.add_patch(rect)
    ax.set_title('Frame 1 — Target Selection', fontsize=14)
    ax.legend(loc='upper right')
    ax.axis('off')
    fig.savefig(os.path.join(FIG_DIR, 'fig_frame1_target.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_frame1_target.png')

    # ── Figure 2: Frame 2 with search box ──
    fig, ax = plt.subplots(1, 1, figsize=(6, 6))
    ax.imshow(frame2, cmap='gray', vmin=0, vmax=1)
    rect = Rectangle((search_c0, search_r0), N, N,
                      linewidth=2, edgecolor='blue', facecolor='none', label='Search Region')
    ax.add_patch(rect)
    # Mark detected position using displacement (handles DFT wrapping)
    det_r = search_r0 + N // 2 + dy
    det_c = search_c0 + N // 2 + dx
    ax.plot(det_c, det_r, 'r*', markersize=15, label=f'Detected ({dy},{dx})')
    ax.set_title('Frame 2 — Detection Result', fontsize=14)
    ax.legend(loc='upper right')
    ax.axis('off')
    fig.savefig(os.path.join(FIG_DIR, 'fig_frame2_search.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_frame2_search.png')

    # ── Figure 3: Response heatmap (centred with fftshift) ──
    # fftshift moves zero-displacement to the centre of the map,
    # so negative displacements appear naturally near centre instead of at corners.
    response_shifted = np.fft.fftshift(response)

    fig, ax = plt.subplots(1, 1, figsize=(6, 5))
    # Label axes as displacement from -N/2 to +N/2-1
    extent = [-N//2, N//2, N//2, -N//2]  # left, right, bottom, top
    im = ax.imshow(response_shifted, cmap='hot', interpolation='nearest', extent=extent)
    ax.plot(dx, dy, 'c*', markersize=20, markeredgewidth=1.5,
            markeredgecolor='white', label=f'Peak: displacement ({dy}, {dx})')
    ax.axhline(0, color='white', linewidth=0.5, alpha=0.5)
    ax.axvline(0, color='white', linewidth=0.5, alpha=0.5)
    ax.set_title('Detection Response Map (centred)', fontsize=14)
    ax.legend(loc='upper right', fontsize=10)
    fig.colorbar(im, ax=ax, shrink=0.8)
    ax.set_xlabel('Column displacement')
    ax.set_ylabel('Row displacement')
    fig.savefig(os.path.join(FIG_DIR, 'fig_response_map.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_response_map.png')

    # ── Figure 4: 2×2 pipeline composite ──
    fig, axes = plt.subplots(2, 2, figsize=(10, 9))

    axes[0, 0].imshow(target_patch, cmap='gray', vmin=0, vmax=1)
    axes[0, 0].set_title('(a) Target Patch (Frame 1)', fontsize=11)
    axes[0, 0].axis('off')

    axes[0, 1].imshow(windowed_target, cmap='gray')
    axes[0, 1].set_title('(b) Hann-Windowed Target', fontsize=11)
    axes[0, 1].axis('off')

    axes[1, 0].imshow(search_patch, cmap='gray', vmin=0, vmax=1)
    axes[1, 0].set_title('(c) Search Patch (Frame 2)', fontsize=11)
    axes[1, 0].axis('off')

    extent = [-N//2, N//2, N//2, -N//2]
    im = axes[1, 1].imshow(response_shifted, cmap='hot', interpolation='nearest', extent=extent)
    axes[1, 1].plot(dx, dy, 'c*', markersize=18, markeredgewidth=1.5,
                    markeredgecolor='white')
    axes[1, 1].axhline(0, color='white', linewidth=0.5, alpha=0.3)
    axes[1, 1].axvline(0, color='white', linewidth=0.5, alpha=0.3)
    axes[1, 1].set_title(f'(d) Response — displacement ({dy}, {dx})', fontsize=11)
    fig.colorbar(im, ax=axes[1, 1], shrink=0.8)

    fig.suptitle('KCF Detection Pipeline: Input → Output', fontsize=14, fontweight='bold')
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(os.path.join(FIG_DIR, 'fig_pipeline_demo.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_pipeline_demo.png')


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='KCF Real-Image Demo')
    parser.add_argument('frame1', nargs='?', default=None, help='Path to frame 1 (or only) image')
    parser.add_argument('frame2', nargs='?', default=None, help='Path to frame 2 image')
    parser.add_argument('--row', type=int, default=None, help='Target centre row in frame 1')
    parser.add_argument('--col', type=int, default=None, help='Target centre col in frame 1')
    parser.add_argument('--shift-row', type=int, default=3,
                        help='Simulated motion in rows (single-image mode, default=3)')
    parser.add_argument('--shift-col', type=int, default=2,
                        help='Simulated motion in cols (single-image mode, default=2)')
    args = parser.parse_args()

    os.makedirs(DATA_DIR, exist_ok=True)

    # ── Load or generate frames ──
    if args.frame1 and args.frame2:
        # Two real images provided
        print(f'Loading real images: {args.frame1}, {args.frame2}')
        frame1 = load_image_gray(args.frame1)
        frame2 = load_image_gray(args.frame2)
        h, w = frame1.shape
        print(f'  Frame size: {h}×{w}')

        if args.row is not None and args.col is not None:
            target_row, target_col = args.row, args.col
            print(f'  Target centre (from args): ({target_row}, {target_col})')
        else:
            print('  No --row/--col provided. Opening interactive selector...')
            matplotlib.use('TkAgg')
            target_row, target_col = select_target(frame1)

    elif args.frame1:
        # Single image — simulate motion by cropping search patch from shifted location
        print(f'Single image mode: {args.frame1}')
        full_img = load_image_gray(args.frame1)
        h, w = full_img.shape
        print(f'  Image size: {h}×{w}')

        if args.row is not None and args.col is not None:
            target_row, target_col = args.row, args.col
            print(f'  Target centre (from args): ({target_row}, {target_col})')
        else:
            print('  No --row/--col provided. Opening interactive selector...')
            matplotlib.use('TkAgg')
            target_row, target_col = select_target(full_img)

        dr, dc = args.shift_row, args.shift_col
        print(f'  Simulated motion: dy={dr}, dx={dc} pixels')
        print(f'  Target crops from ({target_row}, {target_col})')
        print(f'  Search crops from ({target_row + dr}, {target_col + dc})')
        print(f'  Expected KCF displacement: dy={-dr}, dx={-dc}')

        # Both frames are the same image.
        # Target patch crops at (target_row, target_col).
        # Search patch crops at (target_row + dr, target_col + dc).
        # From the search patch's perspective, the target moved by (-dr, -dc).
        frame1 = full_img
        frame2 = full_img  # same image — the "motion" is in where we crop

    else:
        print('No images provided — generating synthetic demo frames.')
        frame1, frame2, target_row, target_col = generate_synthetic_frames()
        print(f'  Frame size: {frame1.shape[0]}×{frame1.shape[1]}')
        print(f'  Target centre: ({target_row}, {target_col})')

    # ── Crop target from frame 1 ──
    target_patch, t_r0, t_c0 = crop_patch(frame1, target_row, target_col)
    print(f'\n  Target patch cropped from ({t_r0}, {t_c0}) to ({t_r0+N}, {t_c0+N})')
    print(f'  Patch intensity range: [{target_patch.min():.3f}, {target_patch.max():.3f}]')

    # ── Train alpha on target ──
    hann_1d = make_hann()
    alpha_hat, X_hat_train, windowed_target = train_alpha(target_patch, hann_1d)

    # Combined filter for hardware: the hardware computes Z_hat * conj(stored).
    # Correct KCF detection: response = IFFT(conj(X_train) * Z * alpha)
    # So we store: conj(alpha) * X_train  (hardware conjugates it → alpha * conj(X_train))
    # Then: Z_hat * conj(stored) = Z_hat * alpha * conj(X_train) = correct!
    combined = np.conj(alpha_hat) * X_hat_train

    max_combined = np.max(np.abs(combined))
    print(f'  max|alpha_hat| = {np.max(np.abs(alpha_hat)):.4f}')
    print(f'  max|combined_filter| = {max_combined:.4f}')

    # Adaptive K: largest power-of-2 such that max|combined*K| < 120
    K = 1
    while K * 2 * max_combined < 120.0:
        K *= 2
    if K < 1:
        K = 1
    print(f'  Auto-selected K={K} (max|combined*K| = {max_combined * K:.2f})')

    combined_scaled = combined * K
    max_stored = np.max(np.abs(combined_scaled))
    clip_count = np.sum(np.abs(combined_scaled) > 127.996)
    print(f'  Stored filter scaled by K={K}: max = {max_stored:.4f}')
    print(f'  Values that will clip: {clip_count} / {N*N}')
    print(f'  NOTE: Hardware pipeline output = (K/N) * response = ({K}/{N}) * response')

    # Write combined filter to alpha_hat.mem (same format: interleaved re/im)
    alpha_values = []
    for r in range(N):
        for c in range(N):
            alpha_values.append(float_to_q88(combined_scaled[r, c].real))
            alpha_values.append(float_to_q88(combined_scaled[r, c].imag))
    write_mem('alpha_hat.mem', alpha_values)

    # ── Crop search patch from frame 2 ──
    # In single-image mode, crop from shifted location to simulate motion
    search_row = target_row + (args.shift_row if args.frame1 and not args.frame2 else 0)
    search_col = target_col + (args.shift_col if args.frame1 and not args.frame2 else 0)
    search_patch, s_r0, s_c0 = crop_patch(frame2, search_row, search_col)
    print(f'\n  Search patch cropped from ({s_r0}, {s_c0}) to ({s_r0+N}, {s_c0+N})')

    # Write test_patch_32.mem
    patch_values = [float_to_q88(search_patch[r, c]) for r in range(N) for c in range(N)]
    write_mem('test_patch_32.mem', patch_values)

    # ── Run Python detection (golden reference) ──
    # Correct KCF: response = IFFT(conj(X_train) * Z_hat * alpha_hat)
    peak_row, peak_col, response, windowed_search = detect(
        search_patch, alpha_hat, X_hat_train, hann_1d)

    # The peak gives displacement from (0,0) in DFT coordinates.
    # Displacement = peak if peak < N/2, else peak - N (circular wrap).
    dy = peak_row if peak_row < N // 2 else peak_row - N
    dx = peak_col if peak_col < N // 2 else peak_col - N

    print(f'\n  GOLDEN REFERENCE:')
    print(f'  Detection peak at ({peak_row}, {peak_col})')
    print(f'  Displacement: dy={dy}, dx={dx}')
    print(f'  Peak value: {response[peak_row, peak_col]:.6f}')
    print(f'  New target position: ({target_row + dy}, {target_col + dx})')

    # ── Generate figures ──
    print('\nGenerating figures...')
    generate_figures(frame1, frame2, t_r0, t_c0, s_r0, s_c0,
                     target_patch, search_patch,
                     windowed_target, windowed_search,
                     response, peak_row, peak_col)

    # ── Summary ──
    print(f'\n=== Summary ===')
    print(f'  Frame 1 target: centre ({target_row}, {target_col})')
    print(f'  Frame 2 detection: peak ({peak_row}, {peak_col}), displacement ({dy}, {dx})')
    print(f'  .mem files written to data/ — ready for Verilog simulation')
    print(f'  Figures saved to docs/MidTerm Report/')
    print(f'\n  To run Verilog: compile all src/*.sv + tb/tb_kcf_detect_top.sv, run 200us')


if __name__ == '__main__':
    main()
