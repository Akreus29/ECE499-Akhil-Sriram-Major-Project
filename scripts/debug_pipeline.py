"""
debug_pipeline.py
Simulates the hardware KCF pipeline step by step in Python,
using the same Q8.8 quantization at each stage, to identify
where precision is lost.
"""
import numpy as np

N = 32
FRAC = 8
SCALE = 1 << FRAC  # 256

def to_q88(val):
    """Float -> Q8.8 signed 16-bit (as Python int, signed)."""
    q = int(round(val * SCALE))
    q = max(-32768, min(32767, q))
    return q

def from_q88(q):
    """Q8.8 signed 16-bit -> float."""
    if q > 32767:
        q -= 65536
    return q / SCALE

def q88_mul(a, b):
    """Q8.8 * Q8.8 with truncation to Q8.8 (matching cmul.v)."""
    full = a * b  # 32-bit
    result = (full >> FRAC) & 0xFFFF
    if result > 32767:
        result -= 65536
    return result

# --- Load the same data the hardware uses ---
def load_mem_signed(path, count):
    vals = []
    with open(path) as f:
        for line in f:
            v = int(line.strip(), 16)
            if v > 32767:
                v -= 65536
            vals.append(v)
    return vals[:count]

def load_mem_unsigned(path, count):
    vals = []
    with open(path) as f:
        for line in f:
            vals.append(int(line.strip(), 16))
    return vals[:count]

# Load data
patch_raw = load_mem_signed('data/test_patch_32.mem', N*N)
hann_raw = load_mem_unsigned('data/hann_32.mem', N)
alpha_flat = load_mem_signed('data/alpha_hat.mem', 2*N*N)
alpha_re_raw = [alpha_flat[2*i] for i in range(N*N)]
alpha_im_raw = [alpha_flat[2*i+1] for i in range(N*N)]

# --- Stage 1: Hann windowing (matching hardware) ---
win_re = []
for idx in range(N*N):
    r = idx // N
    c = idx % N
    hr = hann_raw[r]  # unsigned Q8.8
    hc = hann_raw[c]
    # hann_2d = (hr * hc) >> 8, truncated to 16 bits [23:8]
    # In hardware: $signed({1'b0, hann_val_r}) * $signed({1'b0, hann_val_c})
    # hann values are unsigned, extended to signed 17-bit, then multiplied
    hann_prod = hr * hc  # both positive, no sign issue
    hann_2d = (hann_prod >> FRAC) & 0xFFFF
    if hann_2d > 32767:
        hann_2d -= 65536
    # win_val = (patch * hann_2d) >> 8
    win_prod = patch_raw[idx] * hann_2d
    wv = (win_prod >> FRAC) & 0xFFFF
    if wv > 32767:
        wv -= 65536
    win_re.append(wv)

print("=== Stage 1: Hann Window ===")
print(f"  max|win_re| = {max(abs(v) for v in win_re)} raw = {max(abs(v) for v in win_re)/256:.4f} float")
print(f"  win_re[0:5] = {win_re[0:5]}")

# --- Stage 2: 2D FFT with scaling (1/N per dimension) ---
# Simulate using numpy, then quantize to Q8.8
# Actually, to match hardware we'd need to simulate the iterative FFT.
# Instead, let's compute the expected FFT output magnitude range.
win_float = np.array([v / SCALE for v in win_re]).reshape(N, N)
X_hat = np.fft.fft2(win_float)

# Hardware FFT with SCALE_EN=1 divides by N (5 stages of >>>1 in 1D, done twice for 2D)
# Actually, for 2D: row FFT divides by N, column FFT divides by N, total /N^2?
# NO - each 1D FFT has log2(N)=5 stages with >>>1, giving /N per 1D FFT.
# 2D does row FFT (/N) then column FFT (/N), so total scaling = /N^2? No...
#
# Wait. The scaled FFT formula: at each butterfly stage, outputs are (a+Wb)>>1 and (a-Wb)>>1.
# After log2(N)=5 stages, each output is scaled by 1/2^5 = 1/32 = 1/N.
# For 2D: row FFT scales by 1/N, column FFT scales by 1/N. Total: 1/N^2.
#
# So X_hat_hw ≈ FFT(win) / N^2? That would make the output tiny...
# Actually no: numpy FFT uses no scaling (FFT = sum x*e^{-j2pi...}),
# so FFT(win) has magnitude up to N^2 * max_input.
# Hardware FFT with 1/N per dimension gives FFT(win)/N^2.
# Which is equivalent to the normalized DFT: X[k] = (1/N^2) sum x[n]*e^{...}

X_hat_hw_float = X_hat / (N * N)  # What hardware should produce

print("\n=== Stage 2: FFT2D (SCALE_EN=1) ===")
print(f"  numpy FFT max|X_hat| = {np.max(np.abs(X_hat)):.4f}")
print(f"  hardware FFT max|X_hat/N^2| = {np.max(np.abs(X_hat_hw_float)):.4f}")
print(f"  In Q8.8 raw: {np.max(np.abs(X_hat_hw_float)) * 256:.1f}")

# --- Stage 3: Element multiply ---
# conj(alpha) * X_hat_hw (via cconj_mul which computes alpha * conj(X_hat_hw))
# For real-valued result, both give the same IFFT real part.
alpha_float = np.array([complex(alpha_re_raw[i]/SCALE, alpha_im_raw[i]/SCALE)
                        for i in range(N*N)]).reshape(N, N)

product_float = np.conj(alpha_float) * X_hat_hw_float
print("\n=== Stage 3: Element Multiply ===")
print(f"  max|alpha| = {np.max(np.abs(alpha_float)):.4f}")
print(f"  max|product| = {np.max(np.abs(product_float)):.4f}")
print(f"  In Q8.8 raw: {np.max(np.abs(product_float)) * 256:.1f}")

# --- Stage 4: IFFT (SCALE_EN=1) ---
# IFFT_hw uses conjugate trick: conj(FFT_hw(conj(X)))
# FFT_hw includes 1/N per dimension, so IFFT_hw = conj(FFT(conj(X))/N^2)
# Standard IFFT = conj(FFT(conj(X)))/N^2
# So IFFT_hw = standard_IFFT? Let me verify...
# conj(FFT_hw(conj(X))) = conj(FFT(conj(X)) / N^2) = conj(FFT(conj(X))) / N^2 = IFFT(X)
# YES! IFFT_hw(X) = IFFT(X) = standard inverse FFT

response = np.fft.ifft2(product_float).real
print("\n=== Stage 4: IFFT2D ===")
print(f"  max|response| = {np.max(np.abs(response)):.6f}")
print(f"  In Q8.8 raw: {np.max(np.abs(response)) * 256:.3f}")
peak = np.unravel_index(np.argmax(response), (N, N))
print(f"  Peak at: row={peak[0]}, col={peak[1]}")
print(f"  Peak value: {response[peak]:.6f} = {response[peak]*256:.3f} Q8.8 raw")

# Check what the actual hardware scaling is
# The 1D FFT with SCALE_EN=1 has 5 stages of >>>1 = divide by 32 = divide by N
# 2D FFT = row FFT (each row /N) + column FFT (each column /N) = total /N^2
# So X_hat_hw = numpy_FFT / N^2

# But wait - is this right? numpy FFT of a 2D array:
# X[k1,k2] = sum_{n1} sum_{n2} x[n1,n2] * exp(-j2pi*n1*k1/N) * exp(-j2pi*n2*k2/N)
# Our hardware does row FFT first, then column FFT.
# Row FFT: for each row r, Y[r,k] = sum_c x[r,c] * exp(-j2pi*c*k/N) / N
# Column FFT: for each col k, X[m,k] = sum_r Y[r,k] * exp(-j2pi*r*m/N) / N
# = sum_r (sum_c x[r,c] * exp(-j2pi*c*k/N) / N) * exp(-j2pi*r*m/N) / N
# = (1/N^2) * sum_r sum_c x[r,c] * exp(-j2pi*(r*m+c*k)/N)
# This is (1/N^2) * numpy_FFT2D. Correct!

print("\n=== Summary ===")
print(f"  The hardware pipeline output = (K/{N}^2) * standard_response")
K = 8
print(f"  With K={K}: output = ({K}/{N*N}) * response")
print(f"  = {K/(N*N):.6f} * {np.max(response) / (K/(N*N)):.4f}")
# Wait, that's circular. Let me compute from scratch.

# Python golden: response = IFFT(conj(alpha_unscaled) * FFT(patch))
# where alpha_unscaled = alpha_hat (not pre-scaled)
# Hardware with pre-scaled alpha (K=8):
#   X_hat_hw = FFT(patch) / N^2  [WRONG - see below]

# Actually wait. I need to re-examine.
# The fft2d_32 with SCALE_EN=1 passes SCALE_EN to fft1d_32.
# fft1d_32 does log2(N)=5 stages with >>>1 per butterfly.
# This is applied per 1D FFT call.
# fft2d_32 does:
#   1. Row FFT: applies 1D FFT to each row -> each row divided by N
#   2. Column FFT: applies 1D FFT to each column -> each column divided by N
# Total: output divided by N^2 compared to standard FFT.
#
# IFFT uses conj(FFT_hw(conj(X))):
# = conj(FFT(conj(X)) / N^2)
# = conj(FFT(conj(X))) / N^2
#
# Standard IFFT(X) = conj(FFT(conj(X))) / N^2  (for 2D)
# So IFFT_hw(X) = standard IFFT(X)! Great.
#
# Full pipeline:
# 1. X_hat_hw = FFT(windowed_patch) / N^2
# 2. product = conj(alpha_scaled) * X_hat_hw = K * conj(alpha) * FFT(patch) / N^2
# 3. response_hw = IFFT_hw(product) = IFFT(K * conj(alpha) * FFT(patch) / N^2)
#    = (K/N^2) * IFFT(conj(alpha) * FFT(patch))
#    = (K/N^2) * golden_response
#
# With K=8, N=32: K/N^2 = 8/1024 = 0.0078125
# golden peak ≈ 1.0 (self-detection with DFT-centred label)

# Let me compute the actual golden response
print("\n=== Recompute golden ===")
# Redo from original (not quantized) values
patch = np.zeros((N, N))
patch[:, :] = 0.1
feat_r, feat_c = 18, 20
for dr in range(-2, 3):
    for dc in range(-2, 3):
        r, c = feat_r + dr, feat_c + dc
        if 0 <= r < N and 0 <= c < N:
            patch[r, c] = 0.8

hann_1d = np.array([0.5 * (1 - np.cos(2 * np.pi * n / (N - 1))) for n in range(N)])
hann_2d = np.outer(hann_1d, hann_1d)
windowed = patch * hann_2d

sigma = 2.0
y = np.zeros((N, N))
for r in range(N):
    for c in range(N):
        dr = min(r, N - r)
        dc = min(c, N - c)
        y[r, c] = np.exp(-(dr**2 + dc**2) / (2 * sigma**2))

X_hat_full = np.fft.fft2(windowed)
Y_hat = np.fft.fft2(y)
K_hat = np.conj(X_hat_full) * X_hat_full
lam = 1e-4
alpha_hat = Y_hat / (K_hat + lam)

golden_response = np.fft.ifft2(np.conj(alpha_hat) * X_hat_full).real
golden_peak = np.unravel_index(np.argmax(golden_response), (N, N))
print(f"  Golden response peak: ({golden_peak[0]}, {golden_peak[1]})")
print(f"  Golden peak value: {golden_response[golden_peak]:.6f}")

# Hardware output
hw_factor = K / (N * N)  # K=8
print(f"\n  Hardware output = {hw_factor:.6f} * golden")
print(f"  Hardware peak value = {golden_response[golden_peak] * hw_factor:.6f}")
print(f"  In Q8.8 raw = {golden_response[golden_peak] * hw_factor * 256:.3f}")
print(f"\n  THIS IS THE PROBLEM: the peak is < 1 LSB in Q8.8!")
print(f"  Need K = N^2 = {N*N} to fully compensate, but that causes overflow.")
print(f"  Need wider data path or different scaling strategy.")
