`timescale 1ns/1ps
// tb_fft1d.v — testbench for fft1d_64.v

module tb_fft1d;

    parameter N          = 64;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;

    reg  clk = 0, rst_n = 0, start = 0;
    reg  signed [DATA_WIDTH-1:0] in_re [0:N-1];
    reg  signed [DATA_WIDTH-1:0] in_im [0:N-1];
    wire signed [DATA_WIDTH-1:0] out_re [0:N-1];
    wire signed [DATA_WIDTH-1:0] out_im [0:N-1];
    wire done;

    always #5 clk = ~clk;

    fft1d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .in_re(in_re), .in_im(in_im),
        .out_re(out_re), .out_im(out_im),
        .done(done)
    );

    integer i;
    initial begin
        // DC impulse test: in[0]=1.0, rest=0 → FFT should be all-ones
        for (i = 0; i < N; i = i+1) begin
            in_re[i] = (i == 0) ? (1 << FRAC) : 0;
            in_im[i] = 0;
        end

        #20 rst_n = 1;
        #10 start = 1;
        #10 start = 0;

        wait(done);
        $display("FFT1D DC test: out_re[0]=%0d (expect %0d)", out_re[0], N * (1 << FRAC));

        // TODO: compare all 64 outputs against Python/numpy golden values
        $finish;
    end

endmodule
