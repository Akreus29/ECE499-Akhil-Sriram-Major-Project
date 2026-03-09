`timescale 1ns/1ps
// tb_kcf_detect_top.v
// End-to-end integration testbench for the scaled-down KCF detection pipeline.
// Loads test_patch_32.mem, runs detection, checks peak against golden reference.

module tb_kcf_detect_top;

    parameter N          = 32;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;
    parameter TOTAL      = N * N;

    reg  clk = 0;
    reg  rst_n = 0;
    reg  start = 0;

    // Patch loading interface
    reg  [$clog2(TOTAL)-1:0]       patch_addr;
    reg  signed [DATA_WIDTH-1:0]   patch_data;
    reg                            patch_wr_en;

    // Outputs
    wire [$clog2(N)-1:0]           peak_row, peak_col;
    wire signed [DATA_WIDTH-1:0]   peak_val;
    wire                           done;

    // Clock: 10 ns period (100 MHz)
    always #5 clk = ~clk;

    kcf_detect_top #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .patch_addr(patch_addr), .patch_data(patch_data),
        .patch_wr_en(patch_wr_en),
        .peak_row(peak_row), .peak_col(peak_col),
        .peak_val(peak_val),
        .done(done)
    );

    // Test patch storage
    reg signed [DATA_WIDTH-1:0] patch_mem [0:TOTAL-1];
    integer i;

    initial begin
        $dumpfile("kcf_detect.vcd");
        $dumpvars(0, tb_kcf_detect_top);

        // Load test patch
        $readmemh("C:/Users/Admin/Documents/work/ECE499/ECE499-Akhil-Sriram-Major-Project/data/test_patch_32.mem", patch_mem);

        // Reset
        rst_n = 0;
        patch_wr_en = 0;
        start = 0;
        #20;
        rst_n = 1;
        #10;

        // Write patch into DUT
        $display("Loading patch...");
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            patch_addr  <= i;
            patch_data  <= patch_mem[i];
            patch_wr_en <= 1;
        end
        @(posedge clk);
        patch_wr_en <= 0;

        // Start detection
        $display("Starting detection...");
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // Wait for done
        @(posedge done);
        @(posedge clk);  // let outputs settle

        $display("═══════════════════════════════════════════");
        $display("  KCF Detection Result");
        $display("  Peak at: row=%0d, col=%0d", peak_row, peak_col);
        $display("  Peak value: %0d (Q8.8 = %f)", peak_val, $itor(peak_val) / 256.0);
        $display("═══════════════════════════════════════════");

        // Dump full response map for Python comparison
        begin
            integer fd, ri;
            fd = $fopen("C:/Users/Admin/Documents/work/ECE499/ECE499-Akhil-Sriram-Major-Project/data/hw_response.mem", "w");
            if (fd) begin
                for (ri = 0; ri < TOTAL; ri = ri + 1) begin
                    $fwrite(fd, "%04x\n", dut.resp_map[ri]);
                end
                $fclose(fd);
                $display("  Response map written to data/hw_response.mem");
            end else begin
                $display("  WARNING: Could not open data/hw_response.mem for writing");
            end
        end

        #100;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #10_000_000;  // 10 ms
        $display("TIMEOUT: simulation took too long");
        $finish;
    end

endmodule
