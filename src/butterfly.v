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
    parameter FRAC       = 8,   // fractional bits
    parameter SCALE_EN   = 1    // 1 = >>>1 per stage (scaled FFT), 0 = no scaling
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

    // Q8.8 × Q8.8 → Q16.16 in 32 bits. Keep bits [23:8] to recover Q8.8.
    localparam MSB = FRAC + DATA_WIDTH - 1;   // 23
    localparam LSB = FRAC;                     // 8

    // Twiddle product:  tw = W * b  (complex multiply)
    wire signed [2*DATA_WIDTH-1:0] tw_re_full = (w_re * in_re_b) - (w_im * in_im_b);
    wire signed [2*DATA_WIDTH-1:0] tw_im_full = (w_re * in_im_b) + (w_im * in_re_b);

    wire signed [DATA_WIDTH-1:0] tw_re = tw_re_full[MSB:LSB];
    wire signed [DATA_WIDTH-1:0] tw_im = tw_im_full[MSB:LSB];

    // Butterfly: sum and difference.
    // If SCALE_EN=1, apply >>>1 (scaled FFT) to prevent overflow.
    // If SCALE_EN=0, no scaling (used for IFFT to preserve magnitude).
    generate
        if (SCALE_EN) begin : scaled
            assign out_re_a = (in_re_a + tw_re) >>> 1;
            assign out_im_a = (in_im_a + tw_im) >>> 1;
            assign out_re_b = (in_re_a - tw_re) >>> 1;
            assign out_im_b = (in_im_a - tw_im) >>> 1;
        end else begin : unscaled
            assign out_re_a = in_re_a + tw_re;
            assign out_im_a = in_im_a + tw_im;
            assign out_re_b = in_re_a - tw_re;
            assign out_im_b = in_im_a - tw_im;
        end
    endgenerate

endmodule
