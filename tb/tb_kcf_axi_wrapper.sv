`timescale 1ns/1ps
// tb_kcf_axi_wrapper.sv
//
// End-to-end testbench for kcf_axi_wrapper:
//   1. Write THRESHOLD via AXI4-Lite
//   2. Stream patch_1 (test_patch_32.mem)  via AXI4-Stream
//   3. Issue start via AXI4-Lite CTRL register
//   4. Poll done via AXI4-Lite CTRL register
//   5. Read and display PEAK_ROW / PEAK_COL / PEAK_VAL / TARGET_FOUND
//   6. Repeat steps 2-5 for patch_2 (test2_patch_32.mem)
//
// Results should match tb_kcf_detect_top reference output.

module tb_kcf_axi_wrapper;

    // ── Parameters ──────────────────────────────────────────────────────
    parameter DATA_WIDTH = 16;
    parameter ADDR_WIDTH = 32;
    parameter N          = 32;
    parameter TOTAL      = N * N;   // 1024
    parameter CLK_HALF   = 5;       // 100 MHz (10 ns period)

    // Base path for data files — matches kcf_detect_top's absolute paths
    localparam string DATA_DIR = "C:/Users/Admin/Documents/work/ECE499/ECE499-Akhil-Sriram-Major-Project/data";

    // AXI4-Lite register offsets
    localparam [31:0] CTRL_ADDR         = 32'h00;
    localparam [31:0] THRESHOLD_ADDR    = 32'h04;
    localparam [31:0] PEAK_ROW_ADDR     = 32'h08;
    localparam [31:0] PEAK_COL_ADDR     = 32'h0C;
    localparam [31:0] PEAK_VAL_ADDR     = 32'h10;
    localparam [31:0] TARGET_FOUND_ADDR = 32'h14;

    // ── Clock and reset ──────────────────────────────────────────────────
    reg clk   = 0;
    reg rst_n = 0;

    always #CLK_HALF clk = ~clk;

    // ── AXI4-Stream master signals ───────────────────────────────────────
    reg [DATA_WIDTH-1:0] s_axis_tdata  = 0;
    reg                  s_axis_tvalid = 0;
    wire                 s_axis_tready;
    reg                  s_axis_tlast  = 0;

    // ── AXI4-Lite master signals ─────────────────────────────────────────
    reg [ADDR_WIDTH-1:0] s_axi_awaddr  = 0;
    reg                  s_axi_awvalid = 0;
    wire                 s_axi_awready;

    reg [31:0]           s_axi_wdata   = 0;
    reg [3:0]            s_axi_wstrb   = 4'hF;
    reg                  s_axi_wvalid  = 0;
    wire                 s_axi_wready;

    wire [1:0]           s_axi_bresp;
    wire                 s_axi_bvalid;
    reg                  s_axi_bready  = 0;

    reg [ADDR_WIDTH-1:0] s_axi_araddr  = 0;
    reg                  s_axi_arvalid = 0;
    wire                 s_axi_arready;

    wire [31:0]          s_axi_rdata;
    wire [1:0]           s_axi_rresp;
    wire                 s_axi_rvalid;
    reg                  s_axi_rready  = 0;

    // ── DUT ─────────────────────────────────────────────────────────────
    kcf_axi_wrapper #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .N          (N)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready)
    );

    // ════════════════════════════════════════════════════════════════════
    //  Tasks
    // ════════════════════════════════════════════════════════════════════

    // ── axi_write: drive one AXI4-Lite write transaction ─────────────
    //   Asserts awvalid + wvalid simultaneously (most common SoC DMA pattern).
    //   Waits for address handshake, data handshake, then write response.
    task axi_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk); #1;
        s_axi_awaddr  = addr;
        s_axi_awvalid = 1;
        s_axi_wdata   = data;
        s_axi_wstrb   = 4'hF;
        s_axi_wvalid  = 1;
        s_axi_bready  = 1;

        // Wait for write address handshake
        @(posedge clk);
        while (!s_axi_awready) @(posedge clk);
        s_axi_awvalid = 0;

        // Wait for write data handshake (may be same or next cycle as awready)
        while (!s_axi_wready) @(posedge clk);
        s_axi_wvalid = 0;

        // Wait for write response
        while (!s_axi_bvalid) @(posedge clk);
        s_axi_bready = 0;
        @(posedge clk);
    end
    endtask

    // ── axi_read: drive one AXI4-Lite read transaction ───────────────
    task axi_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge clk); #1;
        s_axi_araddr  = addr;
        s_axi_arvalid = 1;
        s_axi_rready  = 1;

        // Wait for read address handshake
        @(posedge clk);
        while (!s_axi_arready) @(posedge clk);
        s_axi_arvalid = 0;

        // Wait for read data
        while (!s_axi_rvalid) @(posedge clk);
        data = s_axi_rdata;
        s_axi_rready = 0;
        @(posedge clk);
    end
    endtask

    // ── axis_send_patch: stream 1024 pixels from a .mem file ─────────
    //   Respects TREADY backpressure from the DUT.
    //   Asserts TLAST on the final (1023rd) beat.
    task axis_send_patch(input string memfile);
        reg [15:0] pix_mem [0:TOTAL-1];
        integer    beat;
    begin
        $readmemh(memfile, pix_mem);

        for (beat = 0; beat < TOTAL; beat = beat + 1) begin
            @(posedge clk); #1;
            s_axis_tdata  = pix_mem[beat];
            s_axis_tvalid = 1;
            s_axis_tlast  = (beat == TOTAL - 1) ? 1'b1 : 1'b0;

            // Stall until DUT is ready (backpressure)
            while (!s_axis_tready) begin
                @(posedge clk); #1;
            end
        end

        @(posedge clk); #1;
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
    end
    endtask

    // ── poll_done: poll CTRL[1] with timeout ─────────────────────────
    task poll_done(output reg timed_out);
        reg [31:0] ctrl_val;
        integer    tries;
    begin
        timed_out = 0;
        tries     = 0;
        ctrl_val  = 0;
        while (!ctrl_val[1] && tries < 200_000) begin
            axi_read(CTRL_ADDR, ctrl_val);
            tries = tries + 1;
        end
        if (!ctrl_val[1]) begin
            $display("  ERROR: timeout waiting for done (%0d polls)", tries);
            timed_out = 1;
        end else begin
            $display("  done=1 after %0d polls.", tries);
        end
    end
    endtask

    // ── run_patch: full sequence for one patch ────────────────────────
    task run_patch(input integer patch_num, input string memfile);
        reg [31:0] rd;
        reg        timed_out;
    begin
        $display("");
        $display("  ══════════ Patch %0d: %s ══════════", patch_num, memfile);

        // Wait for wrapper to open tready (STREAM_LOADING state)
        // On first patch this is immediate; on subsequent patches the wrapper
        // transitions after done_latched is set.
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);

        // Stream patch pixels
        $display("  Streaming %0d pixels via AXI4-Stream...", TOTAL);
        axis_send_patch(memfile);
        $display("  Patch loaded.");

        // Trigger KCF start
        axi_write(CTRL_ADDR, 32'h1);
        $display("  start issued via CTRL[0].");

        // Poll for completion
        poll_done(timed_out);

        if (!timed_out) begin
            // Read and display results
            axi_read(PEAK_ROW_ADDR,     rd);
            $display("  PEAK_ROW     = %0d",      rd[4:0]);
            axi_read(PEAK_COL_ADDR,     rd);
            $display("  PEAK_COL     = %0d",      rd[4:0]);
            axi_read(PEAK_VAL_ADDR,     rd);
            $display("  PEAK_VAL     = 0x%04h  (Q8.8 = %f)",
                     rd[15:0], $itor($signed(rd[15:0])) / 256.0);
            axi_read(TARGET_FOUND_ADDR, rd);
            $display("  TARGET_FOUND = %0b",      rd[0]);
            axi_read(CTRL_ADDR,         rd);
            $display("  CTRL         = 0x%08h (done=%0b, target_found=%0b)",
                     rd, rd[1], rd[2]);

            if (rd[2])
                $display("  >>> TARGET FOUND <<<");
            else
                $display("  >>> target NOT found <<<");
        end
    end
    endtask

    // ════════════════════════════════════════════════════════════════════
    //  Main test sequence
    // ════════════════════════════════════════════════════════════════════
    reg [15:0] thresh_mem [0:0];
    reg        to;

    initial begin
        $dumpfile("kcf_axi_wrapper.vcd");
        $dumpvars(0, tb_kcf_axi_wrapper);

        // Release reset after 5 cycles
        #(10 * CLK_HALF);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ── Load threshold from .mem file ────────────────────────────
        $readmemh({DATA_DIR, "/conf_threshold.mem"}, thresh_mem);
        $display("");
        $display("  Threshold: 0x%04h (Q8.8 = %f)",
                 thresh_mem[0], $itor($signed(thresh_mem[0])) / 256.0);
        axi_write(THRESHOLD_ADDR, {16'd0, thresh_mem[0]});
        $display("  THRESHOLD written.");

        // ── Patch 1 ──────────────────────────────────────────────────
        run_patch(1, {DATA_DIR, "/test_patch_32.mem"});

        // ── Patch 2 ──────────────────────────────────────────────────
        run_patch(2, {DATA_DIR, "/test2_patch_32.mem"});

        $display("");
        $display("  ══════════ Simulation complete ══════════");
        #100;
        $finish;
    end

    // ── Watchdog ─────────────────────────────────────────────────────────
    initial begin
        #30_000_000;    // 30 ms — two full detection runs
        $display("WATCHDOG: simulation exceeded 30 ms. Aborting.");
        $finish;
    end

endmodule
