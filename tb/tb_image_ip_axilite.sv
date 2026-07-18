`timescale 1ns/1ps
// tb_image_ip_axilite.sv
// Smoke test of the full N=64 IP through its processor interface:
//   AXI4-Lite register writes/reads + AXI4-Stream template/patch streaming.
//
// Sequence (NCC-only mode, auto-correlation test):
//   1. Reset; wait for kcf_top's automatic Y_hat init to finish.
//   2. AXI-Lite: MODE=1 (NCC), THRESH=0x0080, IRQ_MASK=1.
//   3. Stream 4096-pixel template (TUSER=1, constant 0.5), CTRL.tmpl_init.
//   4. Wait for template FFT (ncc tmpl_ready).
//   5. Stream 4096-pixel patch (TUSER=0, constant 0.5).
//   6. CTRL.start; poll STATUS until done.
//   7. Expect PEAK=(0,0), CONFIDENCE>0, STATUS.algo=NCC, IRQ pending.
//   8. W1C the IRQ; verify irq_out deasserts.

module tb_image_ip_axilite;

    parameter N          = 64;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;
    parameter TOTAL      = N * N;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;   // 50 MHz

    // AXI4-Stream master
    reg  [DATA_WIDTH-1:0] s_axis_tdata  = 0;
    reg                   s_axis_tvalid = 0;
    wire                  s_axis_tready;
    reg                   s_axis_tlast  = 0;
    reg                   s_axis_tuser  = 0;

    // AXI4-Lite master
    reg  [31:0] s_axi_awaddr = 0;
    reg         s_axi_awvalid = 0;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata = 0;
    reg  [3:0]  s_axi_wstrb = 4'hF;
    reg         s_axi_wvalid = 0;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready = 1;
    reg  [31:0] s_axi_araddr = 0;
    reg         s_axi_arvalid = 0;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready = 1;

    wire irq_out;

    image_ip_axilite #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .s_axis_tuser(s_axis_tuser),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .irq_out(irq_out)
    );

    integer errors = 0;

    // ── AXI-Lite write task ─────────────────────────────────────────────
    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk); #1;
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1;
            s_axi_wdata   = data;
            s_axi_wvalid  = 1;
            // Wait for both handshakes (may complete on different cycles)
            fork
                begin : aw_hs
                    while (!(s_axi_awvalid && s_axi_awready)) @(posedge clk);
                    #1 s_axi_awvalid = 0;
                end
                begin : w_hs
                    while (!(s_axi_wvalid && s_axi_wready)) @(posedge clk);
                    #1 s_axi_wvalid = 0;
                end
            join
            // Wait for write response
            while (!s_axi_bvalid) @(posedge clk);
            @(posedge clk); #1;
        end
    endtask

    // ── AXI-Lite read task ──────────────────────────────────────────────
    reg [31:0] rd_val;
    task axi_read;
        input [31:0] addr;
        begin
            @(posedge clk); #1;
            s_axi_araddr  = addr;
            s_axi_arvalid = 1;
            while (!s_axi_rvalid) @(posedge clk);
            rd_val = s_axi_rdata;
            #1 s_axi_arvalid = 0;
            @(posedge clk); #1;
        end
    endtask

    // ── Stream one N*N frame of a constant value ────────────────────────
    task stream_frame;
        input [DATA_WIDTH-1:0] value;
        input                  is_template;
        integer k;
        begin
            for (k = 0; k < TOTAL; k = k + 1) begin
                @(posedge clk); #1;
                s_axis_tdata  = value;
                s_axis_tuser  = is_template;
                s_axis_tlast  = (k == TOTAL-1);
                s_axis_tvalid = 1;
                // hold until accepted (tready is constant-1 here, but be safe)
                while (!s_axis_tready) @(posedge clk);
            end
            @(posedge clk); #1;
            s_axis_tvalid = 0;
            s_axis_tlast  = 0;
        end
    endtask

    integer poll_count;

    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;

        // 1. Wait for KCF Y_hat auto-init (not required for NCC mode, but
        //    mirrors the documented software bring-up sequence)
        $display("Waiting for KCF Y_hat init...");
        @(posedge dut.u_ip.u_kcf.init_done);
        $display("KCF init done.");

        // 2. Configure: NCC-only mode, threshold 0.5, IRQ enabled
        axi_write(32'h04, 32'h0000_0001);   // MODE = NCC only
        axi_write(32'h08, 32'h0000_0080);   // THRESH = 0.5 (Q8.8)
        axi_write(32'h20, 32'h0000_0001);   // IRQ_MASK = 1

        // 3. Stream template (constant 0.5), then tmpl_init
        $display("Streaming template...");
        stream_frame(16'h0080, 1'b1);
        axi_write(32'h00, 32'h0000_0004);   // CTRL.tmpl_init

        // 4. Wait for template FFT to complete
        $display("Waiting for template FFT...");
        wait (dut.u_ip.u_ncc.tmpl_ready == 1'b1);
        $display("Template ready.");

        // 5. Stream search patch (same constant 0.5 — auto-correlation)
        $display("Streaming patch...");
        stream_frame(16'h0080, 1'b0);

        // 6. Start detection, poll STATUS.done
        axi_write(32'h00, 32'h0000_0001);   // CTRL.start
        $display("Polling STATUS for done...");
        poll_count = 0;
        rd_val = 0;
        while (!rd_val[1]) begin
            axi_read(32'h10);               // STATUS
            poll_count = poll_count + 1;
        end
        $display("Done after %0d polls. STATUS = 0x%08x", poll_count, rd_val);

        if (rd_val[3:2] != 2'b00) begin
            $display("FAIL: STATUS.algo = %0d, expected 0 (NCC)", rd_val[3:2]);
            errors = errors + 1;
        end

        // 7. Read results
        axi_read(32'h14);   // PEAK_ROW
        $display("PEAK_ROW   = %0d", rd_val);
        if (rd_val != 0) begin errors = errors + 1; $display("FAIL: expected row 0"); end

        axi_read(32'h18);   // PEAK_COL
        $display("PEAK_COL   = %0d", rd_val);
        if (rd_val != 0) begin errors = errors + 1; $display("FAIL: expected col 0"); end

        axi_read(32'h1C);   // CONFIDENCE
        $display("CONFIDENCE = %0d (Q8.8 = %f)", $signed(rd_val), $itor($signed(rd_val))/256.0);
        if ($signed(rd_val) <= 0) begin
            errors = errors + 1;
            $display("FAIL: expected positive confidence");
        end

        // 8. IRQ pending must be set and irq_out asserted
        axi_read(32'h24);   // IRQ_STAT
        if (rd_val[0] !== 1'b1 || irq_out !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL: IRQ_STAT=%0d irq_out=%0d, expected both 1", rd_val[0], irq_out);
        end else
            $display("IRQ pending + irq_out asserted.");

        axi_write(32'h24, 32'h0000_0001);   // W1C clear
        axi_read(32'h24);
        if (rd_val[0] !== 1'b0 || irq_out !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: IRQ not cleared (IRQ_STAT=%0d irq_out=%0d)", rd_val[0], irq_out);
        end else
            $display("IRQ W1C clear verified.");

        if (errors == 0)
            $display("tb_image_ip_axilite: ALL TESTS PASSED");
        else
            $display("tb_image_ip_axilite: %0d TEST(S) FAILED", errors);

        #200;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #60_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
