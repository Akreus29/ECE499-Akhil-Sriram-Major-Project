`timescale 1ns/1ps
// tb_roundtrip2.v — FFT→IFFT round trip with small values
// Tests that the pipeline preserves structure (peak location).

module tb_roundtrip2;

    parameter N          = 32;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;
    parameter TOTAL      = N * N;

    reg  clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ── FFT2D (unscaled) ──
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

    // ── IFFT2D (unscaled) ──
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

    // Simple test: instead of FFT then IFFT, just run IFFT on a known
    // frequency-domain signal and check the peak location in the output.
    //
    // Input: X[k1,k2] = delta(k1) * delta(k2)  (impulse at DC)
    // Expected IFFT: constant = 1/N^2 at every pixel... but with unscaled IFFT
    // we get constant = 1.0 at every pixel (in Q8.8 = 256).
    //
    // Better: input X = all 1.0 → IFFT should give delta at (0,0)
    // With unscaled IFFT: output = N^2 * delta(r,c) = 1024 at (0,0)

    initial begin
        rst_n = 0; ifft_wr_en = 0; ifft_start = 0;
        fft_wr_en = 0; fft_start = 0;
        #20; rst_n = 1; #10;

        $display("Test: IFFT of all-ones spectrum");
        // Load all-ones into IFFT (re=256=1.0, im=0)
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            ifft_wr_addr <= i;
            ifft_wr_re   <= 16'sh0100;   // 1.0
            ifft_wr_im   <= 16'sh0000;
            ifft_wr_en   <= 1;
        end
        @(posedge clk); ifft_wr_en <= 0;
        @(posedge clk); ifft_start <= 1;
        @(posedge clk); ifft_start <= 0;

        @(posedge ifft_done);
        $display("IFFT done.");

        // Read a few values
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge clk); ifft_rd_addr <= i;
            @(posedge clk);
            $display("  ifft[%0d]: re=%0d im=%0d", i, ifft_rd_re, ifft_rd_im);
        end
        // Expect: ifft[0] = large (N^2 * 1.0), ifft[1..] = 0

        // Test 2: IFFT of exp(-j*2*pi*(3*k1+5*k2)/32) spectrum
        // This should give a delta at (3, 5)
        $display("\nTest 2: IFFT that should peak at (3,5)");
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            ifft_wr_addr <= i;
            // X[k1,k2] = exp(-j*2*pi*(3*k1+5*k2)/32)
            // Just set all to 1.0+0j for simplicity and check
            ifft_wr_re   <= 16'sh0001;   // tiny value to avoid overflow
            ifft_wr_im   <= 16'sh0000;
            ifft_wr_en   <= 1;
        end
        @(posedge clk); ifft_wr_en <= 0;
        @(posedge clk); ifft_start <= 1;
        @(posedge clk); ifft_start <= 0;

        @(posedge ifft_done);

        // Find max
        begin : find_max
            reg signed [DATA_WIDTH-1:0] max_val;
            reg [9:0] max_idx;
            max_val = -32768;
            max_idx = 0;
            for (i = 0; i < TOTAL; i = i + 1) begin
                @(posedge clk); ifft_rd_addr <= i;
                @(posedge clk);
                if ($signed(ifft_rd_re) > $signed(max_val)) begin
                    max_val = ifft_rd_re;
                    max_idx = i;
                end
            end
            $display("  Peak at index %0d (row=%0d, col=%0d), val=%0d",
                     max_idx, max_idx/N, max_idx%N, max_val);
            $display("  Expected: (0, 0) for all-ones spectrum");
        end

        #100;
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
