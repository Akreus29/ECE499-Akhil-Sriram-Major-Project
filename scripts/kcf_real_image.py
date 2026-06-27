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
from matplotlib.patches import Rectangle, FancyArrowPatch
from mpl_toolkits.mplot3d import Axes3D
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


# ── Presentation Figure Generation ───────────────────────────────────────────

def render_equation(latex_str, filename, fontsize=28):
    """Render a LaTeX equation to a transparent PNG for use in slides."""
    fig, ax = plt.subplots(figsize=(10, 1.8))
    ax.text(0.5, 0.5, f'${latex_str}$', fontsize=fontsize,
            ha='center', va='center', transform=ax.transAxes,
            color='white')
    ax.set_facecolor('none')
    fig.patch.set_alpha(0.0)
    ax.axis('off')
    fig.savefig(os.path.join(FIG_DIR, filename),
                dpi=200, bbox_inches='tight', transparent=True)
    plt.close(fig)


def generate_presentation_figures(full_image, frame1, frame2,
                                   target_row, target_col,
                                   t_r0, t_c0, s_r0, s_c0,
                                   target_patch, search_patch,
                                   windowed_target, windowed_search,
                                   response, peak_row, peak_col,
                                   hann_1d, shift_row, shift_col):
    """Generate high-impact figures for the PowerPoint presentation."""
    matplotlib.use('Agg')
    os.makedirs(FIG_DIR, exist_ok=True)

    dy = peak_row if peak_row < N // 2 else peak_row - N
    dx = peak_col if peak_col < N // 2 else peak_col - N

    # ── Fig 1: Target selection with zoomed inset ──
    fig, ax = plt.subplots(figsize=(12, 7))
    ax.imshow(full_image, cmap='gray', vmin=0, vmax=1)
    rect = Rectangle((t_c0, t_r0), N, N, lw=2.5, edgecolor='red', facecolor='none')
    ax.add_patch(rect)
    ax.set_title('Frame 1 — Target Selection', fontsize=16, fontweight='bold')
    ax.axis('off')
    # Zoomed inset in upper-right
    axins = fig.add_axes([0.62, 0.52, 0.35, 0.42])
    axins.imshow(target_patch, cmap='gray', interpolation='nearest', vmin=0, vmax=1)
    axins.set_title('32x32 Target (zoomed)', fontsize=11, color='red', fontweight='bold')
    for spine in axins.spines.values():
        spine.set_edgecolor('red')
        spine.set_linewidth(2.5)
    axins.set_xticks([])
    axins.set_yticks([])
    # Connector lines
    box_r_center = t_r0 + N // 2
    box_c_right = t_c0 + N
    ax.annotate('', xy=(0.61, 0.92), xytext=(box_c_right / full_image.shape[1], 1.0 - box_r_center / full_image.shape[0]),
                xycoords='figure fraction', textcoords='axes fraction',
                arrowprops=dict(arrowstyle='-', color='red', lw=1.5, ls='--'))
    fig.savefig(os.path.join(FIG_DIR, 'fig_pres_frame1_context.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_pres_frame1_context.png')

    # ── Fig 2: Detection result with both boxes + arrow ──
    fig = plt.figure(figsize=(14, 8))
    # Main image panel
    ax_main = fig.add_axes([0.02, 0.0, 0.60, 0.88])
    ax_main.imshow(full_image, cmap='gray', vmin=0, vmax=1)
    # Dashed red box = original target
    rect1 = Rectangle((t_c0, t_r0), N, N, lw=2, edgecolor='red',
                       facecolor='none', linestyle='--', label='Target (Frame 1)')
    ax_main.add_patch(rect1)
    # Solid blue box = search region
    rect2 = Rectangle((s_c0, s_r0), N, N, lw=2, edgecolor='#4488ff',
                       facecolor='none', label='Search (Frame 2)')
    ax_main.add_patch(rect2)
    # Detected position star
    det_r = s_r0 + N // 2 + dy
    det_c = s_c0 + N // 2 + dx
    ax_main.plot(det_c, det_r, '*', color='lime', markersize=20,
                 markeredgecolor='white', markeredgewidth=1, label=f'Detected ({dy},{dx})')
    # Arrow from search centre to detected position
    search_cr = s_r0 + N // 2
    search_cc = s_c0 + N // 2
    ax_main.annotate('', xy=(det_c, det_r), xytext=(search_cc, search_cr),
                     arrowprops=dict(arrowstyle='->', color='lime', lw=3))
    ax_main.legend(loc='upper left', fontsize=10, framealpha=0.8)
    ax_main.set_title('Detection Result', fontsize=16, fontweight='bold')
    ax_main.axis('off')
    # Text annotation
    ax_main.text(0.5, -0.04, f'Displacement: ({dy}, {dx}) pixels',
                 transform=ax_main.transAxes, ha='center', fontsize=14,
                 fontweight='bold', color='lime',
                 bbox=dict(boxstyle='round,pad=0.3', facecolor='black', alpha=0.7))

    # Right side: zoomed insets
    ax_t = fig.add_axes([0.65, 0.50, 0.32, 0.42])
    ax_t.imshow(target_patch, cmap='gray', interpolation='nearest', vmin=0, vmax=1)
    ax_t.set_title('Target Patch', fontsize=11, color='red', fontweight='bold')
    for spine in ax_t.spines.values():
        spine.set_edgecolor('red')
        spine.set_linewidth(2)
    ax_t.set_xticks([])
    ax_t.set_yticks([])

    ax_s = fig.add_axes([0.65, 0.03, 0.32, 0.42])
    ax_s.imshow(search_patch, cmap='gray', interpolation='nearest', vmin=0, vmax=1)
    ax_s.set_title('Search Patch', fontsize=11, color='#4488ff', fontweight='bold')
    for spine in ax_s.spines.values():
        spine.set_edgecolor('#4488ff')
        spine.set_linewidth(2)
    ax_s.set_xticks([])
    ax_s.set_yticks([])
    # Arrow on search patch showing displacement
    ax_s.annotate('', xy=(N // 2 + dx, N // 2 + dy), xytext=(N // 2, N // 2),
                  arrowprops=dict(arrowstyle='->', color='lime', lw=2.5))
    ax_s.plot(N // 2, N // 2, '+', color='white', markersize=12, markeredgewidth=2)

    fig.savefig(os.path.join(FIG_DIR, 'fig_pres_detection_result.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_pres_detection_result.png')

    # ── Fig 3: Side-by-side patch comparison with pixel grid ──
    diff = np.abs(target_patch - search_patch)
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    titles = ['Target Patch (Frame 1)', 'Search Patch (Frame 2)', '|Difference|']
    data = [target_patch, search_patch, diff]
    colors = ['red', '#4488ff', 'lime']
    cmaps = ['gray', 'gray', 'hot']

    for i, (ax, d, t, c, cm) in enumerate(zip(axes, data, titles, colors, cmaps)):
        ax.imshow(d, cmap=cm, interpolation='nearest', vmin=0,
                  vmax=1 if i < 2 else diff.max())
        ax.set_title(t, fontsize=13, color=c, fontweight='bold')
        # Pixel grid
        for x in range(N + 1):
            ax.axhline(x - 0.5, color='gray', lw=0.3, alpha=0.5)
            ax.axvline(x - 0.5, color='gray', lw=0.3, alpha=0.5)
        # Crosshair at centre
        ax.plot(N // 2, N // 2, '+', color='white', markersize=10, markeredgewidth=1.5)
        if i == 1:
            # Arrow showing displacement on search patch
            ax.annotate('', xy=(N // 2 + dx, N // 2 + dy),
                        xytext=(N // 2, N // 2),
                        arrowprops=dict(arrowstyle='->', color='lime', lw=2.5))
        ax.set_xticks([])
        ax.set_yticks([])
        for spine in ax.spines.values():
            spine.set_edgecolor(c)
            spine.set_linewidth(2)

    fig.suptitle(f'Pixel-Level Comparison — shift ({shift_row},{shift_col}), '
                 f'detected displacement ({dy},{dx})',
                 fontsize=14, fontweight='bold')
    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(os.path.join(FIG_DIR, 'fig_pres_patch_comparison.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_pres_patch_comparison.png')

    # ── Fig 4: 3D response surface ──
    response_shifted = np.fft.fftshift(response)
    fig = plt.figure(figsize=(10, 7))
    ax3 = fig.add_subplot(111, projection='3d')
    rows = np.arange(N) - N // 2
    cols = np.arange(N) - N // 2
    C, R = np.meshgrid(cols, rows)
    ax3.plot_surface(C, R, response_shifted, cmap='hot', edgecolor='none', alpha=0.9)
    # Mark peak
    ax3.scatter([dx], [dy], [response_shifted[N // 2 + dy, N // 2 + dx]],
                color='cyan', s=200, marker='*', zorder=5, edgecolors='white', linewidths=1)
    # Vertical line at peak
    peak_z = response_shifted[N // 2 + dy, N // 2 + dx]
    ax3.plot([dx, dx], [dy, dy], [0, peak_z], color='cyan', lw=2, ls='--')
    ax3.set_xlabel('Column displacement', fontsize=11)
    ax3.set_ylabel('Row displacement', fontsize=11)
    ax3.set_zlabel('Response', fontsize=11)
    ax3.set_title(f'3D Detection Response — Peak at ({dy}, {dx})',
                  fontsize=14, fontweight='bold')
    ax3.view_init(elev=35, azim=-50)
    fig.savefig(os.path.join(FIG_DIR, 'fig_pres_response_3d.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_pres_response_3d.png')

    # ── Fig 5: Hann window effect ──
    hann_2d = np.outer(hann_1d, hann_1d)
    fig, axes = plt.subplots(2, 2, figsize=(10, 9))

    axes[0, 0].plot(hann_1d, color='cyan', lw=2)
    axes[0, 0].set_title('(a) 1D Hann Window (N=32)', fontsize=12, fontweight='bold')
    axes[0, 0].set_xlabel('Index')
    axes[0, 0].set_ylabel('Amplitude')
    axes[0, 0].grid(True, alpha=0.3)
    axes[0, 0].set_xlim(0, N - 1)

    im = axes[0, 1].imshow(hann_2d, cmap='viridis', interpolation='nearest')
    axes[0, 1].set_title('(b) 2D Hann Window', fontsize=12, fontweight='bold')
    fig.colorbar(im, ax=axes[0, 1], shrink=0.8)
    axes[0, 1].set_xticks([])
    axes[0, 1].set_yticks([])

    axes[1, 0].imshow(target_patch, cmap='gray', interpolation='nearest', vmin=0, vmax=1)
    axes[1, 0].set_title('(c) Raw Target Patch', fontsize=12, fontweight='bold')
    axes[1, 0].set_xticks([])
    axes[1, 0].set_yticks([])

    axes[1, 1].imshow(windowed_target, cmap='gray', interpolation='nearest')
    axes[1, 1].set_title('(d) After Hann Windowing', fontsize=12, fontweight='bold')
    axes[1, 1].set_xticks([])
    axes[1, 1].set_yticks([])

    fig.suptitle('Hann Window: Preventing Spectral Leakage', fontsize=14, fontweight='bold')
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(os.path.join(FIG_DIR, 'fig_pres_hann_effect.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_pres_hann_effect.png')

    # ── Fig 6: Gaussian label ──
    y = make_gaussian_label()
    y_shifted = np.fft.fftshift(y)
    fig, axes = plt.subplots(1, 2, figsize=(11, 5))

    im0 = axes[0].imshow(y_shifted, cmap='hot', interpolation='nearest',
                          extent=[-N//2, N//2, N//2, -N//2])
    axes[0].set_title('Desired Response (Gaussian Label)', fontsize=12, fontweight='bold')
    axes[0].set_xlabel('Column')
    axes[0].set_ylabel('Row')
    axes[0].plot(0, 0, 'c+', markersize=15, markeredgewidth=2)
    fig.colorbar(im0, ax=axes[0], shrink=0.8)

    # 1D cross-section through centre
    centre_row = y_shifted[N // 2, :]
    axes[1].plot(np.arange(N) - N // 2, centre_row, 'r-', lw=2.5)
    axes[1].set_title(f'Centre Cross-Section (sigma={SIGMA})', fontsize=12, fontweight='bold')
    axes[1].set_xlabel('Displacement (pixels)')
    axes[1].set_ylabel('Desired response')
    axes[1].grid(True, alpha=0.3)
    axes[1].axvline(0, color='gray', ls='--', alpha=0.5)

    fig.suptitle('Training Label: What the Filter Learns to Produce',
                 fontsize=14, fontweight='bold')
    fig.tight_layout(rect=[0, 0, 1, 0.93])
    fig.savefig(os.path.join(FIG_DIR, 'fig_pres_gaussian_label.png'),
                dpi=150, bbox_inches='tight')
    plt.close(fig)
    print('  Saved fig_pres_gaussian_label.png')

    # ── Render equations as transparent PNGs ──
    eq_dir = os.path.join(FIG_DIR, 'equations')
    os.makedirs(eq_dir, exist_ok=True)

    equations = {
        'eq_mosse.png': r'G = H^{*} \odot F',
        'eq_mosse_filter.png': r'H^{*} = \frac{\sum_i G_i \odot \overline{F_i}}{\sum_i F_i \odot \overline{F_i}}',
        'eq_circulant.png': r'C(\mathbf{x}) = F^{-1} \, \mathrm{diag}(\hat{\mathbf{x}}) \, F',
        'eq_alpha.png': r'\hat{\boldsymbol{\alpha}} = \frac{\hat{\mathbf{y}}}{|\hat{\mathbf{x}}|^2 + \lambda}',
        'eq_detect.png': r'\mathrm{response} = \mathcal{F}^{-1}\!\left\{\overline{\hat{\mathbf{x}}} \odot \hat{\mathbf{z}} \odot \hat{\boldsymbol{\alpha}}\right\}',
        'eq_combined.png': r'\hat{\mathbf{f}}_{\mathrm{stored}} = \overline{\hat{\boldsymbol{\alpha}}} \odot \hat{\mathbf{x}}',
        'eq_hw_detect.png': r'\hat{\mathbf{z}} \cdot \overline{\hat{\mathbf{f}}_{\mathrm{stored}}} = \overline{\hat{\mathbf{x}}} \cdot \hat{\mathbf{z}} \cdot \hat{\boldsymbol{\alpha}}',
        'eq_ifft_trick.png': r'\mathrm{IFFT}(X) = \overline{\mathrm{FFT}(\overline{X})} \;/\; N^2',
    }
    for fname, latex in equations.items():
        render_equation(latex, os.path.join('equations', fname))
    print(f'  Rendered {len(equations)} equation PNGs to equations/')


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
    parser.add_argument('--presentation', action='store_true',
                        help='Generate extra high-impact figures for PowerPoint presentation')
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

    if args.presentation:
        print('\nGenerating presentation figures...')
        # Use full_img if in single-image mode, otherwise frame1
        full_img = full_img if (args.frame1 and not args.frame2) else frame1
        generate_presentation_figures(
            full_img, frame1, frame2,
            target_row, target_col,
            t_r0, t_c0, s_r0, s_c0,
            target_patch, search_patch,
            windowed_target, windowed_search,
            response, peak_row, peak_col,
            hann_1d, args.shift_row, args.shift_col)

    # ── Summary ──
    print(f'\n=== Summary ===')
    print(f'  Frame 1 target: centre ({target_row}, {target_col})')
    print(f'  Frame 2 detection: peak ({peak_row}, {peak_col}), displacement ({dy}, {dx})')
    print(f'  .mem files written to data/ — ready for Verilog simulation')
    print(f'  Figures saved to docs/MidTerm Report/')
    print(f'\n  To run Verilog: compile all src/*.sv + tb/tb_kcf_detect_top.sv, run 200us')


if __name__ == '__main__':
    main()
