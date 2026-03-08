"""
gen_data_32.py
Generates all .mem files for the 32x32 scaled-down KCF detection pipeline.
Also prints the golden-reference peak location for testbench verification.

Output files (in ../data/):
  twiddle_32.mem       — 32 lines, interleaved re/im for W_32^k, k=0..15
  hann_32.mem          — 32 entries, Hann window coefficients (Q8.8 unsigned)
  alpha_hat.mem        — 2048 entries, frozen filter coeffs (interleaved re/im)
  test_patch_32.mem    — 1024 entries, test patch with known feature

Usage:
  python scripts/gen_data_32.py
"""

import numpy as np
import os

N = 32
FRAC = 8                     # Q8.8 format: 8 integer bits, 8 fractional bits
SCALE = 1 << FRAC            # = 256
DATA_DIR = os.path.join(os.path.dirname(__file__), '..', 'data')


def float_to_q88(val):
    """Convert float to Q8.8 signed 16-bit integer (two's complement)."""
    q = int(round(val * SCALE))
    # Clamp to signed 16-bit range
    q = max(-32768, min(32767, q))
    # Return as unsigned 16-bit for hex formatting
    return q & 0xFFFF


def write_mem(filename, values):
    """Write a list of 16-bit hex values to a .mem file, one per line."""
    path = os.path.join(DATA_DIR, filename)
    with open(path, 'w') as f:
        for v in values:
            f.write(f'{v:04x}\n')
    print(f'  Written {len(values)} entries to {path}')


# ── 1. Twiddle factors ──────────────────────────────────────────────────────
# W_N^k = exp(-j * 2*pi*k / N) for k = 0..N/2-1
# Stored interleaved: line 2k = real(W^k), line 2k+1 = imag(W^k)
def gen_twiddle():
    values = []
    for k in range(N // 2):
        angle = -2.0 * np.pi * k / N
        w_re = np.cos(angle)
        w_im = np.sin(angle)
        values.append(float_to_q88(w_re))
        values.append(float_to_q88(w_im))
    write_mem('twiddle_32.mem', values)
    return values


# ── 2. Hann window ──────────────────────────────────────────────────────────
# w[n] = 0.5 * (1 - cos(2*pi*n / (N-1))) for n = 0..N-1
def gen_hann():
    hann = np.array([0.5 * (1 - np.cos(2 * np.pi * n / (N - 1))) for n in range(N)])
    values = [float_to_q88(h) for h in hann]
    write_mem('hann_32.mem', values)
    return hann


# ── 3. Test patch ────────────────────────────────────────────────────────────
# A 32×32 patch with a bright 5×5 square. The square is placed at a known
# offset from centre so the peak finder output can be verified.
# Feature at (row=18, col=20) — offset (dy=+2, dx=+4) from centre (16,16).
def gen_test_patch():
    patch = np.zeros((N, N), dtype=np.float64)
    # Background noise: small constant to avoid all-zeros
    patch[:, :] = 0.1
    # Bright 5×5 block centred at (18, 20)
    feat_r, feat_c = 18, 20
    for dr in range(-2, 3):
        for dc in range(-2, 3):
            r, c = feat_r + dr, feat_c + dc
            if 0 <= r < N and 0 <= c < N:
                patch[r, c] = 0.8
    values = [float_to_q88(patch[r, c]) for r in range(N) for c in range(N)]
    write_mem('test_patch_32.mem', values)
    return patch


# ── 4. Alpha hat (frozen filter) ─────────────────────────────────────────────
# Train the linear-kernel ridge-regression filter on the test patch itself.
# alpha_hat = Y_hat / (conj(X_hat) * X_hat + lambda)
#
# This means: if we run detection on the SAME patch, the peak should be at
# the centre of the Gaussian label (16,16). If the patch is shifted by
# (dy, dx) the peak moves by (-dy, -dx). For our test: the feature is at
# (18,20) and the label is centred at (16,16), so we train on the patch and
# expect detection on the same patch to peak at (16,16).
def gen_alpha(patch, hann):
    # 2D Hann window: outer product of 1D Hann
    hann_2d = np.outer(hann, hann)
    windowed = patch * hann_2d

    # Gaussian desired response centred at (N/2, N/2) = (16, 16)
    sigma = 2.0
    y = np.zeros((N, N))
    for r in range(N):
        for c in range(N):
            # Circular distance (DFT convention)
            dr = min(r, N - r)
            dc = min(c, N - c)
            y[r, c] = np.exp(-(dr**2 + dc**2) / (2 * sigma**2))

    X_hat = np.fft.fft2(windowed)
    Y_hat = np.fft.fft2(y)

    # Linear kernel: K_hat = conj(X_hat) * X_hat = |X_hat|^2 (real-valued)
    K_hat = np.conj(X_hat) * X_hat
    lam = 1e-2 * SCALE  # lambda in Q8.8-ish scale (small regulariser)
    # Actually lambda should be relative to K_hat magnitude
    lam = 1e-4  # small relative to normalised values

    alpha_hat = Y_hat / (K_hat + lam)

    # ── Golden reference: run detection on the same patch ──
    # response = IFFT( conj(alpha_hat) * X_hat )
    response = np.fft.ifft2(np.conj(alpha_hat) * X_hat).real
    peak = np.unravel_index(np.argmax(response), (N, N))
    print(f'\n  GOLDEN REFERENCE:')
    print(f'  Training patch feature at (18, 20)')
    print(f'  Detection peak at row={peak[0]}, col={peak[1]}')
    print(f'  Expected: (0, 0) for self-detection with DFT-centred label\n')

    # Pre-scale alpha by K to compensate for the forward FFT's 1/N scaling.
    # Forward FFT uses SCALE_EN_ROW=1, SCALE_EN_COL=0 → total /N.
    # IFFT uses SCALE_EN_ROW=1, SCALE_EN_COL=1 → correct 1/N^2.
    # Pipeline output = (K / N) * response_python.
    # K=16 gives output ≈ 0.071 → Q8.8 raw ≈ 18, enough to distinguish.
    # max|alpha*16| ≈ 71.7, |product| ≤ 71.7 * 1.1 ≈ 79 < 128 → no cmul overflow.
    K = 16
    alpha_scaled = alpha_hat * K

    print(f'  Alpha pre-scaling by K={K}:')
    print(f'    max|alpha_hat| = {np.max(np.abs(alpha_hat)):.4f}')
    print(f'    max|alpha_scaled| = {np.max(np.abs(alpha_scaled)):.4f}')
    print(f'    Q8.8 signed max = {127.996:.3f}')
    clip_count = np.sum(np.abs(alpha_scaled) > 127.996)
    print(f'    Values that will clip: {clip_count} / {N*N}')

    # Write alpha_hat interleaved: re[0], im[0], re[1], im[1], ...
    values = []
    for r in range(N):
        for c in range(N):
            values.append(float_to_q88(alpha_scaled[r, c].real))
            values.append(float_to_q88(alpha_scaled[r, c].imag))
    write_mem('alpha_hat.mem', values)

    return alpha_hat, peak


# ── Run everything ───────────────────────────────────────────────────────────
if __name__ == '__main__':
    os.makedirs(DATA_DIR, exist_ok=True)
    print('Generating 32x32 KCF data files...\n')

    gen_twiddle()
    hann = gen_hann()
    patch = gen_test_patch()
    alpha_hat, peak = gen_alpha(patch, hann)

    print('Done. All files written to data/')
    print(f'Golden peak: row={peak[0]}, col={peak[1]}')
