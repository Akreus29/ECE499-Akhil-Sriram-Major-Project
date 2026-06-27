`timescale 1ns/1ps
// tb_fft1d_64.sv
// Verifies fft1d_64 on two inputs:
//   1. Impulse at index 0  → all-ones spectrum (real = 1.0, imag = 0)
//   2. Constant 1.0        → impulse at bin 0 (DC = N = 64), rest zero
// Expected values in Q8.8: 1.0 = 0x0100 = 256d, 64.0 = 0x4000 = 16384d

module tb_fft1d_64;
    parameter N          = 64;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;

    reg clk = 0;
    reg rst_n = 0;
    reg start = 0;
    reg scale_en = 0;   // no scaling for this test

    reg  signed [DATA_WIDTH-1:0] in_re [0:N-1];
    reg  signed [DATA_WIDTH-1:0] in_im [0:N-1];
    wire signed [DATA_WIDTH-1:0] out_re [0:N-1];
    wire signed [DATA_WIDTH-1:0] out_im [0:N-1];
    wire done;

    always #5 clk = ~clk;

    fft1d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .scale_en(scale_en),
        .in_re(in_re), .in_im(in_im),
        .out_re(out_re), .out_im(out_im), .done(done)
    );

    integer i;
    integer errors;

    task run_fft;
        input [127:0] label;
        begin
            @(posedge clk); #1;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait(done);
            @(posedge clk); #1;
        end
    endtask

    initial begin
        // ── Test 1: impulse at index 0 ───────────────────────────────────
        for (i = 0; i < N; i = i + 1) begin
            in_re[i] = (i == 0) ? 16'sd256 : 16'sd0;   // 1.0 at index 0
            in_im[i] = 0;
        end

        @(posedge clk); rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        run_fft("impulse");

        errors = 0;
        for (i = 0; i < N; i = i + 1) begin
            // All bins should be 1.0 (0x0100) ± 2 LSB rounding
            if (out_re[i] < 254 || out_re[i] > 258) begin
                $display("FAIL impulse re[%0d] = %0d (expected ~256)", i, out_re[i]);
                errors = errors + 1;
            end
            if (out_im[i] < -2 || out_im[i] > 2) begin
                $display("FAIL impulse im[%0d] = %0d (expected ~0)", i, out_im[i]);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS: impulse test (all bins = 1.0)");

        // ── Test 2: constant 1.0 → DC bin = N = 64.0, rest ≈ 0 ──────────
        for (i = 0; i < N; i = i + 1) begin
            in_re[i] = 16'sd256;    // 1.0 Q8.8
            in_im[i] = 0;
        end

        repeat(2) @(posedge clk);
        run_fft("constant");

        errors = 0;
        // DC bin (index 0): should be N * 1.0 = 64 * 256 = 16384 (0x4000)
        if (out_re[0] < 16380 || out_re[0] > 16388) begin
            $display("FAIL constant re[0] = %0d (expected ~16384)", out_re[0]);
            errors = errors + 1;
        end
        for (i = 1; i < N; i = i + 1) begin
            if (out_re[i] < -4 || out_re[i] > 4) begin
                $display("FAIL constant re[%0d] = %0d (expected ~0)", i, out_re[i]);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS: constant test (DC = 64.0, others ≈ 0)");

        $display("tb_fft1d_64 done");
        $finish;
    end

    // Timeout
    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
