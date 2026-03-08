`timescale 1ns/1ps
// fft1d_64.v
// 64-point 1D radix-2 DIT FFT.
// Used for both row-wise and column-wise passes in fft2d_64.
// log2(64) = 6 stages, each stage contains 32 butterfly units.

module fft1d_64 #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,       // pulse to begin FFT
    // Input sample stream (real only for first pass; complex thereafter)
    input  wire signed [DATA_WIDTH-1:0]  in_re [0:N-1],
    input  wire signed [DATA_WIDTH-1:0]  in_im [0:N-1],
    // Output spectrum
    output reg  signed [DATA_WIDTH-1:0]  out_re [0:N-1],
    output reg  signed [DATA_WIDTH-1:0]  out_im [0:N-1],
    output reg                           done         // high for 1 cycle when result valid
);

    // TODO: bit-reversal permutation
    // TODO: 6-stage butterfly pipeline using butterfly.v and twiddle_rom.v

endmodule
