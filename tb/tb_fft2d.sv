`timescale 1ns/1ps
// tb_fft2d.v — testbench for fft2d_64.v and ifft2d_64.v
// Smoke test: FFT2D followed by IFFT2D should recover the original patch.

module tb_fft2d;

    parameter N          = 64;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;

    reg  clk = 0, rst_n = 0;
    reg  start_fft = 0, start_ifft = 0;

    reg  signed [DATA_WIDTH-1:0] patch_in  [0:N*N-1];
    wire signed [DATA_WIDTH-1:0] fft_re    [0:N*N-1];
    wire signed [DATA_WIDTH-1:0] fft_im    [0:N*N-1];
    wire                         fft_done;

    wire signed [DATA_WIDTH-1:0] ifft_re   [0:N*N-1];
    wire signed [DATA_WIDTH-1:0] ifft_im   [0:N*N-1];
    wire                         ifft_done;

    always #5 clk = ~clk;

    fft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_fft (
        .clk(clk), .rst_n(rst_n), .start(start_fft),
        .in_re(patch_in),
        .out_re(fft_re), .out_im(fft_im),
        .done(fft_done)
    );

    ifft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_ifft (
        .clk(clk), .rst_n(rst_n), .start(start_ifft),
        .in_re(fft_re), .in_im(fft_im),
        .out_re(ifft_re), .out_im(ifft_im),
        .done(ifft_done)
    );

    integer i;
    initial begin
        // Load test patch from .mem file
        $readmemh("../data/test_patch.mem", patch_in);

        #20 rst_n = 1;
        #10 start_fft = 1; #10 start_fft = 0;
        wait(fft_done);

        start_ifft = 1; #10 start_ifft = 0;
        wait(ifft_done);

        // Check round-trip: ifft_re[i] ≈ patch_in[i]
        for (i = 0; i < N*N; i = i+1) begin
            if ($signed(ifft_re[i]) - $signed(patch_in[i]) > 2 ||
                $signed(patch_in[i]) - $signed(ifft_re[i]) > 2)
                $display("MISMATCH at %0d: got %0d expected %0d", i, ifft_re[i], patch_in[i]);
        end
        $display("FFT2D round-trip test done.");
        $finish;
    end

endmodule
