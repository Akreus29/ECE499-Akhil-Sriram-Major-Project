`timescale 1ns/1ps
// ifft2d_64.v
// 64x64 2D IFFT via conjugate trick:
//   IFFT(X) = (1/N^2) * conj( FFT( conj(X) ) )
// Reuses fft2d_64 with conjugated inputs and outputs.

module ifft2d_64 #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           start,
    input  wire signed [DATA_WIDTH-1:0]   in_re  [0:N*N-1],
    input  wire signed [DATA_WIDTH-1:0]   in_im  [0:N*N-1],
    output reg  signed [DATA_WIDTH-1:0]   out_re [0:N*N-1],
    output reg  signed [DATA_WIDTH-1:0]   out_im [0:N*N-1],
    output reg                            done
);

    // TODO: negate in_im before passing to fft2d_64
    // TODO: negate out_im and scale by 1/N^2 after FFT

endmodule
