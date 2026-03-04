`timescale 1ns/1ps
// gauss_label_rom.v
// ROM of the 64x64 Gaussian desired response map y.
// y[r,c] = exp( -( (r - cy)^2 + (c - cx)^2 ) / (2*sigma^2) )
// Centred at (cy, cx) = (N/2, N/2). Stored in data/gauss_label_64.mem.

module gauss_label_rom #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16
)(
    input  wire [$clog2(N*N)-1:0]        addr,   // row-major: addr = row*N + col
    output reg  [DATA_WIDTH-1:0]         y_out
);

    reg [DATA_WIDTH-1:0] mem [0:N*N-1];

    initial begin
        $readmemh("../data/gauss_label_64.mem", mem);
    end

    always @(*) begin
        y_out = mem[addr];
    end

endmodule
