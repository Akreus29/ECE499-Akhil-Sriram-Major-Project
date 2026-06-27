`timescale 1ns/1ps
// twiddle_rom.sv
// ROM of twiddle factors W_64^k = exp(-j2πk/64) for k = 0..31.
// Interleaved format (same as twiddle_rom_32.sv):
//   twiddle_64.mem line 2k = real part, line 2k+1 = imag part.
// Q8.8 signed fixed-point. 64 entries total (32 complex pairs).

module twiddle_rom #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire [$clog2(N/2)-1:0]        addr,   // k = 0..31
    output wire signed [DATA_WIDTH-1:0]  w_re,
    output wire signed [DATA_WIDTH-1:0]  w_im
);

    // Flat interleaved array: 64 entries (32 pairs × 2)
    reg signed [DATA_WIDTH-1:0] mem [0:N-1];

    initial begin
        $readmemh("../data/twiddle_64.mem", mem);
    end

    assign w_re = mem[{addr, 1'b0}];
    assign w_im = mem[{addr, 1'b1}];

endmodule
