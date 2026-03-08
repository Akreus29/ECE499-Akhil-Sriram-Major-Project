`timescale 1ns/1ps
// hann_rom.v
// ROM of 64-point Hann (cosine) window coefficients.
// w[n] = 0.5 * (1 - cos(2*pi*n / (N-1))),  n = 0..63
// Values stored as Q8.8 unsigned fixed-point in data/hann_64.mem.

module hann_rom #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16
)(
    input  wire [$clog2(N)-1:0]          addr,
    output reg  [DATA_WIDTH-1:0]         w_out
);

    reg [DATA_WIDTH-1:0] mem [0:N-1];

    initial begin
        $readmemh("../data/hann_64.mem", mem);
    end

    always @(*) begin
        w_out = mem[addr];
    end

endmodule
