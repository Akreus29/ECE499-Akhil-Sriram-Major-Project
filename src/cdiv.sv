`timescale 1ns/1ps
// cdiv.v
// Complex element-wise divider: out = num / (denom_re + lambda)
// Used in KCF filter update: alpha = Y_hat / (K_hat + lambda)
// denom is purely real (kernel response + regularisation scalar).
//   out_re = num_re / (denom_re + lambda)
//   out_im = num_im / (denom_re + lambda)

module cdiv #(
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire signed [DATA_WIDTH-1:0] num_re,
    input  wire signed [DATA_WIDTH-1:0] num_im,
    input  wire signed [DATA_WIDTH-1:0] denom_re, // real denominator (K_hat)
    input  wire signed [DATA_WIDTH-1:0] lambda,   // regularisation constant
    output wire signed [DATA_WIDTH-1:0] out_re,
    output wire signed [DATA_WIDTH-1:0] out_im,
    output wire                         div_by_zero
);

    // d = denom_re + lambda  (real Q8.8 denominator)
    // recip = 2^(2*FRAC) / d  → Q8.8 reciprocal (computed as integer 65536/d)
    // out_re = (num_re * recip) >> FRAC
    // out_im = (num_im * recip) >> FRAC

    wire signed [DATA_WIDTH:0]   d_full = $signed(denom_re) + $signed(lambda);

    // Protect against non-positive denominator
    assign div_by_zero = (d_full <= 0);

    wire [DATA_WIDTH-1:0] d_pos = div_by_zero ? 16'd1 : d_full[DATA_WIDTH-1:0];

    // Q8.8 reciprocal: 65536 / d_pos  (2*FRAC = 16, so recip = 1/d in Q8.8 * 256)
    wire [2*DATA_WIDTH-1:0] recip_wide = 32'd65536 / d_pos;
    wire signed [DATA_WIDTH-1:0] recip  = recip_wide[DATA_WIDTH-1:0];

    wire signed [2*DATA_WIDTH-1:0] re_full = $signed(num_re) * recip;
    wire signed [2*DATA_WIDTH-1:0] im_full = $signed(num_im) * recip;

    assign out_re = div_by_zero ? 0 : re_full[FRAC+DATA_WIDTH-1:FRAC];
    assign out_im = div_by_zero ? 0 : im_full[FRAC+DATA_WIDTH-1:FRAC];

endmodule
