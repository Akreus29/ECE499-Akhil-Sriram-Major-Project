`timescale 1ns/1ps
// twiddle_rom.v
// Read-only memory of twiddle factors W_N^k = exp(-j2πk/N) for N=64.
// Values stored as Q8.8 fixed-point pairs (real, imag).
// Initialized from data/twiddle_64.mem at synthesis/simulation time.

module twiddle_rom #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire [$clog2(N/2)-1:0] addr,   // index k = 0 .. N/2-1
    output reg  signed [DATA_WIDTH-1:0] w_re,
    output reg  signed [DATA_WIDTH-1:0] w_im
);

    reg signed [DATA_WIDTH-1:0] re_mem [0:N/2-1];
    reg signed [DATA_WIDTH-1:0] im_mem [0:N/2-1];

    initial begin
        $readmemh("../data/twiddle_64.mem", re_mem);
        // TODO: separate file for imag, or interleaved format
    end

    always @(*) begin
        w_re = re_mem[addr];
        w_im = im_mem[addr];
    end

endmodule
