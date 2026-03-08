`timescale 1ns/1ps
// twiddle_rom_32.v
// ROM of twiddle factors W_32^k = exp(-j2πk/32) for k = 0..15.
// Stored interleaved in twiddle_32.mem: line 2k = real, line 2k+1 = imag.
// Q8.8 signed fixed-point.

module twiddle_rom_32 #(
    parameter N          = 32,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire [$clog2(N/2)-1:0]       addr,   // k = 0..15
    output wire signed [DATA_WIDTH-1:0] w_re,
    output wire signed [DATA_WIDTH-1:0] w_im
);

    // Flat array: 32 entries (16 pairs × 2)
    reg signed [DATA_WIDTH-1:0] mem [0:N-1];

    initial begin
        $readmemh("data/twiddle_32.mem", mem);
    end

    // addr*2 = {addr, 1'b0},  addr*2+1 = {addr, 1'b1}
    assign w_re = mem[{addr, 1'b0}];
    assign w_im = mem[{addr, 1'b1}];

endmodule
