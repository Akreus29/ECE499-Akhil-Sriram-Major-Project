`timescale 1ns/1ps
// butterfly.v
// Radix-2 DIT butterfly unit.
// Computes:
//   out_a = a + W*b,   out_b = a - W*b
// With optional >>>1 scaling controlled by runtime signal scale_en.

module butterfly #(
    parameter DATA_WIDTH = 16,  // total bits (Q8.8)
    parameter FRAC       = 8    // fractional bits
)(
    input  wire                         scale_en,   // 1 = >>>1, 0 = no scaling
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

    // Q8.8 x Q8.8 -> Q16.16 in 32 bits. Keep bits [23:8] to recover Q8.8.
    localparam MSB = FRAC + DATA_WIDTH - 1;   // 23
    localparam LSB = FRAC;                     // 8

    // Twiddle product:  tw = W * b  (complex multiply)
    wire signed [2*DATA_WIDTH-1:0] tw_re_full = (w_re * in_re_b) - (w_im * in_im_b);
    wire signed [2*DATA_WIDTH-1:0] tw_im_full = (w_re * in_im_b) + (w_im * in_re_b);

    wire signed [DATA_WIDTH-1:0] tw_re = tw_re_full[MSB:LSB];
    wire signed [DATA_WIDTH-1:0] tw_im = tw_im_full[MSB:LSB];

    // Sum / difference
    wire signed [DATA_WIDTH-1:0] sum_re  = in_re_a + tw_re;
    wire signed [DATA_WIDTH-1:0] sum_im  = in_im_a + tw_im;
    wire signed [DATA_WIDTH-1:0] diff_re = in_re_a - tw_re;
    wire signed [DATA_WIDTH-1:0] diff_im = in_im_a - tw_im;

    // Conditionally scale by 1/2
    assign out_re_a = scale_en ? (sum_re  >>> 1) : sum_re;
    assign out_im_a = scale_en ? (sum_im  >>> 1) : sum_im;
    assign out_re_b = scale_en ? (diff_re >>> 1) : diff_re;
    assign out_im_b = scale_en ? (diff_im >>> 1) : diff_im;

endmodule
