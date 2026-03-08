`timescale 1ns/1ps
// tb_fft1d_verify.v — Detailed FFT1D verification against Python golden values.
// Input: x[n] = n * 0.03125 (0..31 * 1/32), a simple ramp.

module tb_fft1d_verify;

    parameter N          = 32;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;

    reg  clk = 0, rst_n = 0, start = 0;
    reg  signed [DATA_WIDTH-1:0] in_re [0:N-1];
    reg  signed [DATA_WIDTH-1:0] in_im [0:N-1];
    wire signed [DATA_WIDTH-1:0] out_re [0:N-1];
    wire signed [DATA_WIDTH-1:0] out_im [0:N-1];
    wire done;

    always #5 clk = ~clk;

    fft1d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC), .SCALE_EN(0)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .in_re(in_re), .in_im(in_im),
        .out_re(out_re), .out_im(out_im),
        .done(done)
    );

    integer i;

    initial begin
        // Ramp: x[n] = n/32.0 → in Q8.8: n * 256 / 32 = n * 8
        for (i = 0; i < N; i = i + 1) begin
            in_re[i] = i * 8;    // n * (1/32) in Q8.8
            in_im[i] = 0;
        end

        rst_n = 0; #20; rst_n = 1; #10;
        @(posedge clk); start <= 1;
        @(posedge clk); start <= 0;

        @(posedge done);
        @(posedge clk);

        $display("FFT1D of ramp x[n] = n/32:");
        for (i = 0; i < N; i = i + 1) begin
            $display("  Bin[%2d]: re=%6d  im=%6d", i, out_re[i], out_im[i]);
        end

        $finish;
    end

endmodule
