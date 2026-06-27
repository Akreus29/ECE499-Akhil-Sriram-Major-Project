`timescale 1ns/1ps
// tb_ncc_top.sv
// Tests the ncc_top 64×64 NCC tracker.
//
// Test 1 — Auto-correlation:
//   template = patch = constant 0.5 (0x0080 Q8.8)
//   After Hann windowing and cross-correlation, the response map peak must be
//   at row=0, col=0 (zero-lag in circular correlation → top-left of response map).
//   The peak must be positive and larger than all other bins.
//
// Test 2 — Orthogonality check:
//   template = constant 1.0, patch = alternating +1/-1 (checkerboard)
//   Cross-correlation of DC template with zero-mean patch should produce a
//   response map whose peak is near zero (all values ≈ 0).
//   Asserts peak_val < 0x0100 (< 1.0 Q8.8) to confirm low correlation.

module tb_ncc_top;
    parameter N          = 64;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;
    parameter TOTAL      = N * N;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    // DUT ports
    reg  [$clog2(TOTAL)-1:0]        tmpl_wr_addr;
    reg  signed [DATA_WIDTH-1:0]    tmpl_wr_data;
    reg                             tmpl_wr_en;
    reg                             tmpl_init;
    wire                            tmpl_ready;

    reg  [$clog2(TOTAL)-1:0]        patch_addr;
    reg  signed [DATA_WIDTH-1:0]    patch_data;
    reg                             patch_wr_en;
    reg                             start;

    wire [$clog2(N)-1:0]            peak_row, peak_col;
    wire signed [DATA_WIDTH-1:0]    peak_val;
    wire                            done;

    ncc_top #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n),
        .tmpl_wr_addr(tmpl_wr_addr), .tmpl_wr_data(tmpl_wr_data),
        .tmpl_wr_en(tmpl_wr_en), .tmpl_init(tmpl_init), .tmpl_ready(tmpl_ready),
        .patch_addr(patch_addr), .patch_data(patch_data),
        .patch_wr_en(patch_wr_en), .start(start),
        .peak_row(peak_row), .peak_col(peak_col),
        .ncc_score(peak_val), .done(done)
    );

    integer i, errors;

    // Write N*N pixels into template buffer
    task write_template;
        input signed [DATA_WIDTH-1:0] val;
        integer k;
        begin
            for (k = 0; k < TOTAL; k = k + 1) begin
                @(posedge clk); #1;
                tmpl_wr_addr = k;
                tmpl_wr_data = val;
                tmpl_wr_en   = 1;
            end
            @(posedge clk); #1;
            tmpl_wr_en = 0;
        end
    endtask

    // Write N*N pixels into patch buffer
    task write_patch_constant;
        input signed [DATA_WIDTH-1:0] val;
        integer k;
        begin
            for (k = 0; k < TOTAL; k = k + 1) begin
                @(posedge clk); #1;
                patch_addr = k;
                patch_data = val;
                patch_wr_en = 1;
            end
            @(posedge clk); #1;
            patch_wr_en = 0;
        end
    endtask

    // Write checkerboard patch: +val at even positions, -val at odd positions
    task write_patch_checker;
        input signed [DATA_WIDTH-1:0] val;
        integer k;
        begin
            for (k = 0; k < TOTAL; k = k + 1) begin
                @(posedge clk); #1;
                patch_addr = k;
                patch_data = (k[0] ^ k[6]) ? -val : val;  // checkerboard in 64×64
                patch_wr_en = 1;
            end
            @(posedge clk); #1;
            patch_wr_en = 0;
        end
    endtask

    // Trigger template init and wait for tmpl_ready
    task do_tmpl_init;
        begin
            @(posedge clk); #1;
            tmpl_init = 1;
            @(posedge clk); #1;
            tmpl_init = 0;
            wait(tmpl_ready);
            @(posedge clk); #1;
        end
    endtask

    // Start detection and wait for done
    task do_detect;
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
        // ── Initialise ─────────────────────────────────────────────────────
        tmpl_wr_en  = 0; tmpl_init = 0;
        patch_wr_en = 0; start     = 0;

        @(posedge clk); rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ════════════════════════════════════════════════════════════════════
        // Test 1: auto-correlation — template = patch = 0.5 (0x0080)
        // ════════════════════════════════════════════════════════════════════
        $display("=== Test 1: auto-correlation (template=patch=0.5) ===");

        write_template(16'sh0080);   // 0.5 in Q8.8
        do_tmpl_init;

        write_patch_constant(16'sh0080);
        do_detect;

        errors = 0;
        // Peak must be at (0, 0) — zero displacement
        if (peak_row !== 0 || peak_col !== 0) begin
            $display("FAIL auto-corr: peak at (%0d,%0d), expected (0,0)", peak_row, peak_col);
            errors = errors + 1;
        end
        // Peak value must be positive
        if ($signed(peak_val) <= 0) begin
            $display("FAIL auto-corr: peak_val = %0d, expected > 0", peak_val);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS auto-corr: peak at (0,0), score = 0x%04h", peak_val);

        // ════════════════════════════════════════════════════════════════════
        // Test 2: low-correlation check — template=1.0, patch=checkerboard
        // ════════════════════════════════════════════════════════════════════
        $display("=== Test 2: low-correlation (template=1.0, patch=checkerboard) ===");

        write_template(16'sh0100);   // 1.0 in Q8.8
        do_tmpl_init;

        write_patch_checker(16'sh0100);
        do_detect;

        errors = 0;
        // For zero-mean checkerboard × DC template, peak should be small
        if ($signed(peak_val) >= 16'sh0100) begin
            $display("FAIL low-corr: peak_val = 0x%04h, expected < 0x0100 (1.0 Q8.8)", peak_val);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS low-corr: peak_val = 0x%04h (below threshold)", peak_val);

        $display("tb_ncc_top done");
        $finish;
    end

    // Timeout
    initial begin
        #100_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
