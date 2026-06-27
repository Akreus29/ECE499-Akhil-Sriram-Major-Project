`timescale 1ns/1ps
// tb_kcf_detect_top.sv
// End-to-end testbench: runs TWO patches through the KCF detection pipeline
// and reports peak displacement + target displacement between images.

module tb_kcf_detect_top;

    parameter N          = 32;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;
    parameter TOTAL      = N * N;

    reg  clk = 0;
    reg  rst_n = 0;
    reg  start = 0;

    reg  [$clog2(TOTAL)-1:0]       patch_addr;
    reg  signed [DATA_WIDTH-1:0]   patch_data;
    reg                            patch_wr_en;
    reg  signed [DATA_WIDTH-1:0]   conf_threshold;

    wire [$clog2(N)-1:0]           peak_row, peak_col;
    wire signed [DATA_WIDTH-1:0]   peak_val;
    wire                           target_found;
    wire                           done;

    always #5 clk = ~clk;   // 100 MHz

    kcf_detect_top #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .patch_addr(patch_addr), .patch_data(patch_data),
        .patch_wr_en(patch_wr_en),
        .conf_threshold(conf_threshold),
        .peak_row(peak_row), .peak_col(peak_col),
        .peak_val(peak_val),
        .target_found(target_found),
        .done(done)
    );

    // Storage for both patches
    reg signed [DATA_WIDTH-1:0] patch1_mem [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] patch2_mem [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] thresh_mem [0:0];

    // Saved results from each test
    reg [$clog2(N)-1:0] result1_row, result1_col;
    reg signed [DATA_WIDTH-1:0] result1_val;
    reg result1_found;
    reg [$clog2(N)-1:0] result2_row, result2_col;
    reg signed [DATA_WIDTH-1:0] result2_val;
    reg result2_found;

    integer i;

    // ── Task: load a patch array into the DUT and run detection ──
    task run_detection;
        input integer test_num;
        begin
            // Reset
            rst_n = 0;
            patch_wr_en = 0;
            start = 0;
            #20;
            rst_n = 1;
            #10;

            // Write patch into DUT
            for (i = 0; i < TOTAL; i = i + 1) begin
                @(posedge clk);
                patch_addr  <= i;
                patch_data  <= (test_num == 1) ? patch1_mem[i] : patch2_mem[i];
                patch_wr_en <= 1;
            end
            @(posedge clk);
            patch_wr_en <= 0;

            // Start detection
            @(posedge clk);
            start <= 1;
            @(posedge clk);
            start <= 0;

            // Wait for done
            @(posedge done);
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("kcf_detect.vcd");
        $dumpvars(0, tb_kcf_detect_top);

        // Load both patches and threshold
        $readmemh("C:/Users/Admin/Documents/work/ECE499/ECE499-Akhil-Sriram-Major-Project/data/test_patch_32.mem",  patch1_mem);
        $readmemh("C:/Users/Admin/Documents/work/ECE499/ECE499-Akhil-Sriram-Major-Project/data/test2_patch_32.mem", patch2_mem);
        $readmemh("C:/Users/Admin/Documents/work/ECE499/ECE499-Akhil-Sriram-Major-Project/data/conf_threshold.mem", thresh_mem);
        conf_threshold = thresh_mem[0];

        $display("");
        $display("  Confidence threshold: 0x%04x (Q8.8 = %f)", conf_threshold, $itor(conf_threshold) / 256.0);

        // ════════════════════════════════════════════════
        //  TEST 1 — Image 1 patch
        // ════════════════════════════════════════════════
        $display("");
        $display("  ============ TEST 1: Image 1 ============");
        $display("  Loading patch 1...");
        run_detection(1);

        result1_row   = peak_row;
        result1_col   = peak_col;
        result1_val   = peak_val;
        result1_found = target_found;

        $display("  Peak at:  row = %0d,  col = %0d", peak_row, peak_col);
        $display("  Peak value: %0d (Q8.8 = %f)", peak_val, $itor(peak_val) / 256.0);
        if (target_found)
            $display("  >>> TARGET FOUND <<<");
        else
            $display("  >>> TARGET NOT FOUND <<<");

        // Dump response map for test 1
        begin
            integer fd, ri;
            fd = $fopen("C:/Users/Admin/Documents/work/ECE499/ECE499-Akhil-Sriram-Major-Project/data/hw_response_img1.mem", "w");
            if (fd) begin
                for (ri = 0; ri < TOTAL; ri = ri + 1)
                    $fwrite(fd, "%04x\n", dut.resp_map[ri]);
                $fclose(fd);
            end
        end

        // ════════════════════════════════════════════════
        //  TEST 2 — Image 2 patch
        // ════════════════════════════════════════════════
        $display("");
        $display("  ============ TEST 2: Image 2 ============");
        $display("  Loading patch 2...");
        run_detection(2);

        result2_row   = peak_row;
        result2_col   = peak_col;
        result2_val   = peak_val;
        result2_found = target_found;

        $display("  Peak at:  row = %0d,  col = %0d", peak_row, peak_col);
        $display("  Peak value: %0d (Q8.8 = %f)", peak_val, $itor(peak_val) / 256.0);
        if (target_found)
            $display("  >>> TARGET FOUND <<<");
        else
            $display("  >>> TARGET NOT FOUND <<<");

        // Dump response map for test 2
        begin
            integer fd, ri;
            fd = $fopen("C:/Users/Admin/Documents/work/ECE499/ECE499-Akhil-Sriram-Major-Project/data/hw_response_img2.mem", "w");
            if (fd) begin
                for (ri = 0; ri < TOTAL; ri = ri + 1)
                    $fwrite(fd, "%04x\n", dut.resp_map[ri]);
                $fclose(fd);
            end
        end

        // ════════════════════════════════════════════════
        //  DISPLACEMENT SUMMARY
        // ════════════════════════════════════════════════
        $display("");
        $display("  =============================================");
        $display("  KCF DISPLACEMENT RESULTS");
        $display("  =============================================");
        $display("  Image 1:  peak_row = %0d,  peak_col = %0d,  peak_val = %0d",
                 result1_row, result1_col, result1_val);
        $display("  Image 2:  peak_row = %0d,  peak_col = %0d,  peak_val = %0d",
                 result2_row, result2_col, result2_val);
        $display("  ---------------------------------------------");
        $display("  Image 1 target_found = %0b", result1_found);
        $display("  Image 2 target_found = %0b", result2_found);
        $display("  =============================================");
        $display("");

        #100;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #20_000_000;  // 20 ms (two full runs)
        $display("TIMEOUT: simulation took too long");
        $finish;
    end

endmodule
