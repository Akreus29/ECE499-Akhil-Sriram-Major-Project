`timescale 1ns/1ps
// butterfly.v
// Radix-2 DIT butterfly unit for use in fft1d_64.
// Computes:
//   out_re_a = in_re_a + (W_re*in_re_b - W_im*in_im_b)
//   out_im_a = in_im_a + (W_re*in_im_b + W_im*in_re_b)
//   out_re_b = in_re_a - (W_re*in_re_b - W_im*in_im_b)
//   out_im_b = in_im_a - (W_re*in_im_b + W_im*in_re_b)

module butterfly #(
    parameter DATA_WIDTH = 16,  // total bits (Q8.8)
    parameter FRAC       = 8    // fractional bits
)(
    input  wire signed [DATA_WIDTH-1:0] in_re_a,
    input  wire signed [DATA_WIDTH-1:0] in_im_a,
    input  wire signed [DATA_WIDTH-1:0] in_re_b,
    input  wire signed [DATA_WIDTH-1:0] in_im_b,
    input  wire signed [DATA_WIDTH-1:0] w_re,   // twiddle real
    input  wire signed [DATA_WIDTH-1:0] w_im,   // twiddle imag

    output wire signed [DATA_WIDTH-1:0] out_re_a,
    output wire signed [DATA_WIDTH-1:0] out_im_a,
    output wire signed [DATA_WIDTH-1:0] out_re_b,
    output wire signed [DATA_WIDTH-1:0] out_im_b
);

    // TODO: implement fixed-point butterfly arithmetic with truncation/rounding

endmodule
