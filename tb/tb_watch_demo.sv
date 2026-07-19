`timescale 1ns/1ps
// =============================================================================
// tb_watch_demo.sv — real-imagery validation for the final demo.
//
// Preloads the Timex-watch designation frame (target_frame.mem, dial centre
// (72,136)) into the frame BRAM, self-designates at boot, then loads the
// separate test frame (test_frame_watch.mem — watch shifted + smaller, with a
// hand distractor) and reports where the tracker locates the watch.
//
// Prints the raw NCC window decision and the reported absolute coordinate so
// we can judge honestly whether the algorithm survives the scale/clutter.
// =============================================================================

module tb_watch_demo;

    parameter FRAME_W = 320, FRAME_H = 240, DEC = 4;
    localparam FRAME_PIXELS = FRAME_W*FRAME_H;
    localparam FRAME_WORDS  = FRAME_PIXELS/2;
    localparam DEC_W = FRAME_W/DEC, DEC_H = FRAME_H/DEC;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  [31:0] s_axi_awaddr = 0;  reg s_axi_awvalid = 0;  wire s_axi_awready;
    reg  [31:0] s_axi_wdata = 0;   reg [3:0] s_axi_wstrb = 4'hF;
    reg         s_axi_wvalid = 0;  wire s_axi_wready;
    wire [1:0]  s_axi_bresp;       wire s_axi_bvalid;  reg s_axi_bready = 1;
    reg  [31:0] s_axi_araddr = 0;  reg s_axi_arvalid = 0;  wire s_axi_arready;
    wire [31:0] s_axi_rdata;       wire [1:0] s_axi_rresp;
    wire        s_axi_rvalid;      reg s_axi_rready = 1;
    wire        irq_out;

    image_ip_axilite #(
        .FRAME_W(FRAME_W), .FRAME_H(FRAME_H),
        .TARGET_MEM("target_frame.mem"),
        .TGT_ROW(9'd72), .TGT_COL(9'd136),
        .AUTO_TINIT(1), .NCC_STRIDE(2)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .irq_out(irq_out)
    );

    // Test-frame image words (same layout as frame_buf)
    reg [15:0] test_words [0:FRAME_WORDS-1];

    task axi_write;
        input [31:0] addr; input [31:0] data;
        begin
            @(posedge clk); #1;
            s_axi_awaddr=addr; s_axi_awvalid=1; s_axi_wdata=data; s_axi_wvalid=1;
            fork
                begin while(!(s_axi_awvalid&&s_axi_awready)) @(posedge clk); #1 s_axi_awvalid=0; end
                begin while(!(s_axi_wvalid&&s_axi_wready)) @(posedge clk); #1 s_axi_wvalid=0; end
            join
            while(!s_axi_bvalid) @(posedge clk);
            @(posedge clk); #1;
        end
    endtask

    reg [31:0] rd_val;
    task axi_read;
        input [31:0] addr;
        begin
            @(posedge clk); #1;
            s_axi_araddr=addr; s_axi_arvalid=1;
            while(!s_axi_rvalid) @(posedge clk);
            rd_val=s_axi_rdata; #1 s_axi_arvalid=0;
            @(posedge clk); #1;
        end
    endtask

    // Backdoor-load the test frame into frame_buf + rebuild dec_buf
    task load_test_frame;
        integer w, dr, dc, i, j, r, c, idx, acc;
        reg [7:0] gr;
        begin
            for (w = 0; w < FRAME_WORDS; w = w + 1)
                dut.u_input.frame_buf[w] = test_words[w];
            for (dr = 0; dr < DEC_H; dr = dr + 1)
                for (dc = 0; dc < DEC_W; dc = dc + 1) begin
                    acc = 0;
                    for (i = 0; i < DEC; i = i + 1)
                        for (j = 0; j < DEC; j = j + 1) begin
                            r = dr*DEC + i; c = dc*DEC + j;
                            idx = r*FRAME_W + c;
                            gr = idx[0] ? test_words[idx>>1][15:8]
                                        : test_words[idx>>1][7:0];
                            acc = acc + gr;
                        end
                    dut.u_input.dec_buf[dr*DEC_W + dc] = acc / 16;
                end
            axi_write(32'h30, 32'd76800);   // frame complete
        end
    endtask

    integer ncc_cycles = 0;
    always @(posedge clk) if (dut.u_ncc.busy) ncc_cycles = ncc_cycles + 1;

    initial begin
        $readmemh("test_frame_watch.mem", test_words);

        rst_n = 0; #100; rst_n = 1;

        $display("Waiting for KCF self-init + boot designation on the watch...");
        @(posedge dut.u_kcf.init_done);
        rd_val = 0; while(!rd_val[1]) axi_read(32'h10);
        axi_read(32'h2C);
        $display("Boot designation done. TARGET_POS = (row %0d, col %0d)",
                 rd_val[8:0], rd_val[24:16]);
        $display("  template mean=%0d  Et=%0d",
                 dut.u_input.tmpl_mean, dut.u_input.tmpl_energy);

        // ── Pure NCC on the test frame (MODE = NCC only) ────────────────
        axi_write(32'h04, 32'h1);        // MODE = NCC only
        axi_write(32'h08, 32'h0);        // THRESH = 0 (report whatever it finds)
        load_test_frame;
        ncc_cycles = 0;
        axi_write(32'h00, 32'h1);        // start
        rd_val = 0; while(!rd_val[1]) axi_read(32'h10);

        $display("");
        $display("=== NCC result on the test frame ===");
        $display("  raw window (decimated)  = (row %0d, col %0d)",
                 dut.u_ncc.best_row, dut.u_ncc.best_col);
        $display("  NCC confidence (Q8.8)   = %0d  (= %0d/256)",
                 dut.u_ncc.confidence, dut.u_ncc.confidence);
        axi_read(32'h14); $display("  ABS_ROW = %0d  (watch dial ~64)", rd_val);
        axi_read(32'h18); $display("  ABS_COL = %0d  (watch dial ~128)", rd_val);
        $display("  NCC took %0d cycles = %0d us @ 50 MHz",
                 ncc_cycles, ncc_cycles/50);

        // ── AUTO mode: does it acquire and switch to KCF? ───────────────
        $display("");
        $display("=== AUTO mode (acquire -> switch to KCF) ===");
        axi_write(32'h04, 32'h0);        // MODE = AUTO
        axi_write(32'h08, 32'h0040);     // THRESH = 0.25
        axi_write(32'h34, 32'h0080);     // KCF_THRESH = 0.5
        load_test_frame;
        axi_write(32'h00, 32'h1);
        rd_val = 0; while(!rd_val[1]) axi_read(32'h10);
        $display("  STATUS=0x%02x  algo=%0d(%s)  tracking=%0d",
                 rd_val, rd_val[3:2], (rd_val[3:2]==0)?"NCC":"KCF", rd_val[4]);
        axi_read(32'h14); $display("  ABS_ROW = %0d", rd_val);
        axi_read(32'h18); $display("  ABS_COL = %0d", rd_val);
        axi_read(32'h1C); $display("  CONFIDENCE = %0d", $signed(rd_val));

        #200; $finish;
    end

    initial begin #200_000_000; $display("TIMEOUT"); $finish; end

endmodule
