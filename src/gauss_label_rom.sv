`timescale 1ns/1ps
// gauss_label_rom.v
// ROM of the 64x64 Gaussian desired response map y.
// y[r,c] = exp( -( (r - cy)^2 + (c - cx)^2 ) / (2*sigma^2) )
// Centred at (cy, cx) = (N/2, N/2). Stored in data/gauss_label_64.mem.
//
// SYNCHRONOUS read (1-cycle latency) so the 4096x16 array infers a
// block RAM instead of ~65k bits of distributed LUT ROM.

module gauss_label_rom #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16
)(
    input  wire                          clk,
    input  wire [$clog2(N*N)-1:0]        addr,   // row-major: addr = row*N + col
    output reg  [DATA_WIDTH-1:0]         y_out   // valid 1 cycle after addr
);

    reg [DATA_WIDTH-1:0] mem [0:N*N-1];

    initial begin
        $readmemh("gauss_label_64.mem", mem);
    end

    always @(posedge clk) begin
        y_out <= mem[addr];
    end

endmodule
