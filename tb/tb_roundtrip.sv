`timescale 1ns/1ps
// tb_roundtrip.v — FFT→IFFT round trip test to isolate where the bug is.
// Load a simple pattern, FFT2D, then IFFT2D, and compare.

module tb_roundtrip;

    parameter N          = 32;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;
    parameter TOTAL      = N * N;

    reg  clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ── FFT2D ──
    reg  [$clog2(TOTAL)-1:0]     fft_wr_addr;
    reg  signed [DATA_WIDTH-1:0] fft_wr_re, fft_wr_im;
    reg                          fft_wr_en, fft_start;
    wire                         fft_done;
    reg  [$clog2(TOTAL)-1:0]     fft_rd_addr;
    wire signed [DATA_WIDTH-1:0] fft_rd_re, fft_rd_im;

    fft2d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC), .SCALE_EN(0)) u_fft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(fft_wr_addr), .wr_data_re(fft_wr_re), .wr_data_im(fft_wr_im),
        .wr_en(fft_wr_en), .start(fft_start),
        .rd_addr(fft_rd_addr), .rd_data_re(fft_rd_re), .rd_data_im(fft_rd_im),
        .done(fft_done)
    );

    // ── IFFT2D ──
    reg  [$clog2(TOTAL)-1:0]     ifft_wr_addr;
    reg  signed [DATA_WIDTH-1:0] ifft_wr_re, ifft_wr_im;
    reg                          ifft_wr_en, ifft_start;
    wire                         ifft_done;
    reg  [$clog2(TOTAL)-1:0]     ifft_rd_addr;
    wire signed [DATA_WIDTH-1:0] ifft_rd_re, ifft_rd_im;

    ifft2d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_ifft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(ifft_wr_addr), .wr_data_re(ifft_wr_re), .wr_data_im(ifft_wr_im),
        .wr_en(ifft_wr_en), .start(ifft_start),
        .rd_addr(ifft_rd_addr), .rd_data_re(ifft_rd_re), .rd_data_im(ifft_rd_im),
        .done(ifft_done)
    );

    integer i;
    reg signed [DATA_WIDTH-1:0] original [0:TOTAL-1];

    initial begin
        rst_n = 0; fft_wr_en = 0; fft_start = 0;
        ifft_wr_en = 0; ifft_start = 0;
        #20; rst_n = 1; #10;

        // Create a simple pattern: impulse at (5, 7)
        for (i = 0; i < TOTAL; i = i + 1) begin
            if (i == 5 * N + 7)
                original[i] = 16'sh0100;   // 1.0
            else
                original[i] = 16'sh0000;
        end

        // Load into FFT2D
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            fft_wr_addr <= i;
            fft_wr_re   <= original[i];
            fft_wr_im   <= 0;
            fft_wr_en   <= 1;
        end
        @(posedge clk); fft_wr_en <= 0;
        @(posedge clk); fft_start <= 1;
        @(posedge clk); fft_start <= 0;

        @(posedge fft_done);
        $display("FFT done. Copying to IFFT...");

        // Copy FFT output into IFFT input
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            fft_rd_addr <= i;
            @(posedge clk);
            ifft_wr_addr <= i;
            ifft_wr_re   <= fft_rd_re;
            ifft_wr_im   <= fft_rd_im;
            ifft_wr_en   <= 1;
        end
        @(posedge clk); ifft_wr_en <= 0;
        @(posedge clk); ifft_start <= 1;
        @(posedge clk); ifft_start <= 0;

        @(posedge ifft_done);
        $display("IFFT done. Checking round-trip...");

        // Read IFFT output and compare
        // The unscaled FFT→IFFT gives N^2 * original (no normalization)
        // So expect: original[i] * 1024
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            ifft_rd_addr <= i;
            @(posedge clk);
            $display("  [%0d] original=%0d  roundtrip=%0d  (expect %0d)",
                     i, original[i], ifft_rd_re, original[i] * TOTAL);
        end

        // Check the impulse location
        @(posedge clk); ifft_rd_addr <= 5 * N + 7;
        @(posedge clk);
        $display("\n  Impulse (5,7): original=%0d roundtrip=%0d (expect %0d)",
                 original[5*N+7], ifft_rd_re, 16'sh0100 * TOTAL);

        #100;
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
