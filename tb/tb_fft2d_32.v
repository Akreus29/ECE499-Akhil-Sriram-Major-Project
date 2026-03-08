`timescale 1ns/1ps
// tb_fft2d_32.v — Test the forward FFT2D by loading a known patch,
// running the FFT, and dumping the first few output bins for comparison
// with Python.

module tb_fft2d_32;

    parameter N          = 32;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;
    parameter TOTAL      = N * N;

    reg  clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // FFT2D interface
    reg  [$clog2(TOTAL)-1:0]       wr_addr;
    reg  signed [DATA_WIDTH-1:0]   wr_data_re, wr_data_im;
    reg                            wr_en;
    reg                            start;
    reg  [$clog2(TOTAL)-1:0]       rd_addr;
    wire signed [DATA_WIDTH-1:0]   rd_data_re, rd_data_im;
    wire                           done;

    fft2d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC), .SCALE_EN(0)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(wr_addr), .wr_data_re(wr_data_re),
        .wr_data_im(wr_data_im), .wr_en(wr_en),
        .start(start),
        .rd_addr(rd_addr), .rd_data_re(rd_data_re), .rd_data_im(rd_data_im),
        .done(done)
    );

    // Simple test: load a small impulse at position (0,0)
    integer i;

    initial begin
        $dumpfile("fft2d_32.vcd");
        $dumpvars(0, tb_fft2d_32);

        rst_n = 0; wr_en = 0; start = 0;
        #20; rst_n = 1; #10;

        // Load: x[0,0] = 1.0 (0x0100), rest = 0
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            wr_addr    <= i;
            wr_data_re <= (i == 0) ? 16'sh0100 : 16'sh0000;
            wr_data_im <= 16'sh0000;
            wr_en      <= 1;
        end
        @(posedge clk);
        wr_en <= 0;

        // Start FFT
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        @(posedge done);
        @(posedge clk);

        // Read first 4 bins
        $display("FFT2D of impulse at (0,0):");
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            rd_addr <= i;
            @(posedge clk);
            $display("  Bin[%0d]: re=%0d im=%0d", i, rd_data_re, rd_data_im);
        end
        // Expect: all bins = (1.0, 0) since FFT of delta = constant
        // In Q8.8 unscaled: re = 256 (=1.0), im = 0

        // Test 2: all 0.25
        @(posedge clk);
        $display("\nFFT2D of constant 0.25:");
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            wr_addr    <= i;
            wr_data_re <= 16'sh0040;   // 0.25 in Q8.8
            wr_data_im <= 16'sh0000;
            wr_en      <= 1;
        end
        @(posedge clk); wr_en <= 0;
        @(posedge clk); start <= 1;
        @(posedge clk); start <= 0;

        @(posedge done);
        @(posedge clk);

        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            rd_addr <= i;
            @(posedge clk);
            $display("  Bin[%0d]: re=%0d im=%0d", i, rd_data_re, rd_data_im);
        end
        // Expect: bin[0] = N^2 * 0.25 = 1024 * 0.25 = 256.0 = 65536 in Q8.8
        // Other bins = 0

        #100;
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
