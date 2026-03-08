`timescale 1ns/1ps
// cmul.v
// Complex multiplier: out = (a_re + j*a_im) * (b_re + j*b_im)
//   out_re = a_re*b_re - a_im*b_im
//   out_im = a_re*b_im + a_im*b_re
// Combinational, Q8.8 fixed-point with truncation to DATA_WIDTH bits.

module cmul #(
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire signed [DATA_WIDTH-1:0] a_re,
    input  wire signed [DATA_WIDTH-1:0] a_im,
    input  wire signed [DATA_WIDTH-1:0] b_re,
    input  wire signed [DATA_WIDTH-1:0] b_im,
    output wire signed [DATA_WIDTH-1:0] out_re,
    output wire signed [DATA_WIDTH-1:0] out_im
);

    localparam MSB = FRAC + DATA_WIDTH - 1;   // 23
    localparam LSB = FRAC;                     // 8

    wire signed [2*DATA_WIDTH-1:0] re_full = (a_re * b_re) - (a_im * b_im);
    wire signed [2*DATA_WIDTH-1:0] im_full = (a_re * b_im) + (a_im * b_re);

    assign out_re = re_full[MSB:LSB];
    assign out_im = im_full[MSB:LSB];

endmodule
