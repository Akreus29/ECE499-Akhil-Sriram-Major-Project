`timescale 1ns/1ps
// peak_finder.v
// Scans the 64x64 response map (real-valued after IFFT) and outputs the
// (row, col) coordinates of the maximum value — the predicted target location.

module peak_finder #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    input  wire signed [DATA_WIDTH-1:0]  response [0:N*N-1],  // row-major
    output reg  [$clog2(N)-1:0]          peak_row,
    output reg  [$clog2(N)-1:0]          peak_col,
    output reg  signed [DATA_WIDTH-1:0]  peak_val,
    output reg                           done
);

    // TODO: sequential scan over N*N elements, track running max

endmodule
