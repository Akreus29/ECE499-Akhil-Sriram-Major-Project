`timescale 1ns/1ps
// fft2d_64.v
// 64x64 2D FFT via row-column decomposition.
// Pass 1: apply fft1d_64 to each of the 64 rows.
// Pass 2: apply fft1d_64 to each of the 64 columns of the result.

module fft2d_64 #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           start,
    // Input patch: N×N samples, row-major, real-valued
    input  wire signed [DATA_WIDTH-1:0]   in_re  [0:N*N-1],
    // Output spectrum: N×N complex
    output reg  signed [DATA_WIDTH-1:0]   out_re [0:N*N-1],
    output reg  signed [DATA_WIDTH-1:0]   out_im [0:N*N-1],
    output reg                            done
);

    // Internal row-pass result buffers
    reg signed [DATA_WIDTH-1:0] row_re [0:N*N-1];
    reg signed [DATA_WIDTH-1:0] row_im [0:N*N-1];

    // TODO: FSM — ROW_PASS → COL_PASS → DONE
    // TODO: instantiate fft1d_64, mux rows then columns

endmodule
