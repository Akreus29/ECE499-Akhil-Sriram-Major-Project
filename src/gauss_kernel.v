`timescale 1ns/1ps
// gauss_kernel.v
// Computes the Gaussian RBF kernel response k(x, x') = exp(-||x - x'||^2 / sigma^2)
// for use in KCF. The squared norm is computed in the frequency domain as:
//   ||x - x'||^2 = ||x||^2 + ||x'||^2 - 2 * IFFT( conj(FFT(x)) * FFT(x') )
// exp() is approximated via a lookup table indexed by the fixed-point input.

module gauss_kernel #(
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8,
    parameter LUT_DEPTH  = 256  // precision of exp LUT
)(
    input  wire                          clk,
    input  wire                          rst_n,
    // Precomputed squared norms (scalar, fixed-point)
    input  wire signed [DATA_WIDTH-1:0]  norm_x_sq,
    input  wire signed [DATA_WIDTH-1:0]  norm_xp_sq,
    // Cross-correlation term from IFFT (real part only)
    input  wire signed [DATA_WIDTH-1:0]  xcorr_re,
    // Gaussian bandwidth parameter
    input  wire signed [DATA_WIDTH-1:0]  sigma_sq,  // sigma^2 in Q8.8
    output wire signed [DATA_WIDTH-1:0]  k_out      // kernel response
);

    // TODO: compute exponent = (norm_x_sq + norm_xp_sq - 2*xcorr_re) / sigma_sq
    // TODO: LUT-based exp(-exponent) approximation

endmodule
