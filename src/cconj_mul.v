`timescale 1ns/1ps
// cconj_mul.v
// Complex conjugate multiplier: out = (a_re + j*a_im) * (b_re - j*b_im)
//   out_re = a_re*b_re + a_im*b_im
//   out_im = a_im*b_re - a_re*b_im
// Used in KCF to compute cross-power spectrum: conj(A) * B in freq domain.

module cconj_mul #(
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire signed [DATA_WIDTH-1:0] a_re,
    input  wire signed [DATA_WIDTH-1:0] a_im,
    input  wire signed [DATA_WIDTH-1:0] b_re,  // conjugated operand
    input  wire signed [DATA_WIDTH-1:0] b_im,
    output wire signed [DATA_WIDTH-1:0] out_re,
    output wire signed [DATA_WIDTH-1:0] out_im
);

    // TODO: implement using cmul with negated b_im, or directly

endmodule
