`timescale 1ns/1ps
// hann_rom_32.v
// ROM of 32-point Hann window coefficients.
// w[n] = 0.5 * (1 - cos(2*pi*n / (N-1))),  n = 0..31
// Values stored as Q8.8 unsigned fixed-point in data/hann_32.mem.

module hann_rom_32 #(
    parameter N          = 32,
    parameter DATA_WIDTH = 16
)(
    input  wire [$clog2(N)-1:0]  addr,
    output wire [DATA_WIDTH-1:0] w_out
);

    reg [DATA_WIDTH-1:0] mem [0:N-1];

    initial begin
        $readmemh("data/hann_32.mem", mem);
    end

    assign w_out = mem[addr];

endmodule
