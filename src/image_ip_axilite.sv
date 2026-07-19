`timescale 1ns/1ps
// =============================================================================
// image_ip_axilite.sv                        (ICD v2 — TOP-LEVEL WRAPPER)
//
// Thin integration top for the KCF/NCC full-frame tracker IP.
// AXI4-Lite ONLY (no AXI-Stream, no DMA).  SoC attachment per ICD:
// slave on the Yamuna slow fabric, clk = core_clk (50 MHz),
// rst_n = ~soc_reset, irq_out reserved (leave unconnected).
//
//   ┌──────────────────────────────────────────────────────────────┐
//   │ image_ip_axilite                                             │
//   │                                                              │
//   │  AXI WRITE ─▶ frame_input_if ──┬─ 320×320 frame BRAM         │
//   │  (AW/W/B)     (INPUT SIDE:     │  80×80 decimated copy       │
//   │               all registers,   │  16×16 NCC template         │
//   │               frame upload,    └─▶ 64×64 crop feed ─▶ kcf_top│
//   │               engines)                                       │
//   │                    │ config/commands                         │
//   │                    ▼                                         │
//   │               track_ctrl ◀─▶ ncc_search (80×80 sliding win)  │
//   │               (acquire →     kcf_top    (64×64 crop track)   │
//   │                lock →                                        │
//   │                fallback)                                     │
//   │                    │ results                                 │
//   │                    ▼                                         │
//   │  AXI READ ◀─ result_output_if  (OUTPUT SIDE: all read-back)  │
//   │  (AR/R)                                                      │
//   └──────────────────────────────────────────────────────────────┘
//
// Collaborator note: model the SoC→IP direction from frame_input_if.sv and
// the IP→SoC direction from result_output_if.sv — this file is only wiring.
// =============================================================================

module image_ip_axilite #(
    parameter FRAME_W    = 320,     // full frame width  (ICD v3: 320×240)
    parameter FRAME_H    = 240,     // full frame height
    parameter PATCH_N    = 64,      // KCF patch / crop dimension
    parameter DEC        = 4,       // NCC decimation factor
    parameter DATA_WIDTH = 16,     // internal Q8.8 lane width
    parameter FRAC       = 8,
    parameter ADDR_WIDTH = 32,
    // ICD v3.1 — preloaded designation (scripts/gen_target_mem.py):
    parameter TARGET_MEM = "target_frame.mem",  // baked designation frame
    parameter [8:0] TGT_ROW = 9'd72,            // baked target centre (watch)
    parameter [8:0] TGT_COL = 9'd136,
    parameter AUTO_TINIT = 1,                   // self-designate at boot
    parameter NCC_STRIDE = 2                    // acquisition search stride
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ── AXI4-Lite slave — write address channel ────────────────────────
    input  wire [ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire                     s_axi_awvalid,
    output wire                     s_axi_awready,

    // ── AXI4-Lite slave — write data channel ──────────────────────────
    input  wire [31:0]              s_axi_wdata,
    input  wire [3:0]               s_axi_wstrb,
    input  wire                     s_axi_wvalid,
    output wire                     s_axi_wready,

    // ── AXI4-Lite slave — write response channel ───────────────────────
    output wire [1:0]               s_axi_bresp,
    output wire                     s_axi_bvalid,
    input  wire                     s_axi_bready,

    // ── AXI4-Lite slave — read address channel ─────────────────────────
    input  wire [ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire                     s_axi_arvalid,
    output wire                     s_axi_arready,

    // ── AXI4-Lite slave — read data channel ───────────────────────────
    output wire [31:0]              s_axi_rdata,
    output wire [1:0]               s_axi_rresp,
    output wire                     s_axi_rvalid,
    input  wire                     s_axi_rready,

    // ── Interrupt (RESERVED — leave unconnected) ───────────────────────
    output wire                     irq_out
);

    // ── Inter-module wiring ─────────────────────────────────────────────
    // Config / commands
    wire [1:0]                    mode;
    wire signed [DATA_WIDTH-1:0]  thresh, kcf_thresh, lambda;
    wire [8:0]                    target_row, target_col;
    wire                          irq_mask, irq_pending;
    wire                          start_pend, tinit_pend, sreset_pulse;
    wire                          start_consume, tinit_consume;
    wire                          frame_complete;
    wire [16:0]                   buf_idx;

    // Engines
    wire        crop_req, crop_done, tinit_req, tinit_done;
    wire [8:0]  crop_row, crop_col;

    // ncc_search
    wire        ncc_start, ncc_done, ncc_busy, ncc_found;
    wire [12:0] dec_rd_addr;
    wire [7:0]  dec_rd_data;
    wire [7:0]  tmpl_rd_addr;
    wire signed [8:0] tmpl_rd_data;
    wire [25:0] tmpl_energy;
    wire [6:0]  ncc_row, ncc_col;
    wire [15:0] ncc_conf;

    // kcf_top
    wire [11:0]                   kcf_patch_addr;
    wire signed [DATA_WIDTH-1:0]  kcf_patch_data;
    wire                          kcf_patch_wr_en;
    wire                          kcf_detect_start, kcf_update_start;
    wire                          kcf_detect_done, kcf_update_done, kcf_init_done;
    wire [5:0]                    kcf_peak_row, kcf_peak_col;
    wire signed [DATA_WIDTH-1:0]  kcf_peak_val;

    // Status / results
    wire                          stat_busy, stat_done, stat_tracking, stat_found, irq_done;
    wire [1:0]                    stat_algo;
    wire [8:0]                    abs_row, abs_col;
    wire signed [DATA_WIDTH-1:0]  confidence;

    assign irq_out = irq_pending & irq_mask;

    // ════════════════════════════════════════════════════════════════════
    //  INPUT SIDE — AXI write path, frame storage, upload, feed engines
    // ════════════════════════════════════════════════════════════════════
    frame_input_if #(
        .FRAME_W(FRAME_W), .FRAME_H(FRAME_H), .PATCH_N(PATCH_N), .DEC(DEC),
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .TARGET_MEM(TARGET_MEM), .TGT_ROW(TGT_ROW), .TGT_COL(TGT_COL)
    ) u_input (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .mode(mode), .thresh(thresh), .kcf_thresh(kcf_thresh), .lambda(lambda),
        .target_row(target_row), .target_col(target_col),
        .irq_mask(irq_mask), .irq_pending(irq_pending), .irq_set(irq_done),
        .start_pend(start_pend), .tinit_pend(tinit_pend),
        .sreset_pulse(sreset_pulse),
        .start_consume(start_consume), .tinit_consume(tinit_consume),
        .frame_complete(frame_complete), .buf_idx(buf_idx),
        .busy(stat_busy),
        .dec_rd_addr(dec_rd_addr), .dec_rd_data(dec_rd_data),
        .tmpl_rd_addr(tmpl_rd_addr), .tmpl_rd_data(tmpl_rd_data),
        .tmpl_energy(tmpl_energy),
        .crop_req(crop_req), .crop_row(crop_row), .crop_col(crop_col),
        .crop_done(crop_done),
        .tinit_req(tinit_req), .tinit_done(tinit_done),
        .kcf_patch_addr(kcf_patch_addr), .kcf_patch_data(kcf_patch_data),
        .kcf_patch_wr_en(kcf_patch_wr_en)
    );

    // ════════════════════════════════════════════════════════════════════
    //  CORE — acquisition, tracking control, trackers
    // ════════════════════════════════════════════════════════════════════
    ncc_search #(
        .DEC_W(FRAME_W/DEC), .DEC_H(FRAME_H/DEC), .TMPL_W(PATCH_N/DEC),
        .STRIDE(NCC_STRIDE)
    ) u_ncc (
        .clk(clk), .rst_n(rst_n),
        .start(ncc_start), .busy(ncc_busy), .done(ncc_done),
        .dec_rd_addr(dec_rd_addr), .dec_rd_data(dec_rd_data),
        .tmpl_rd_addr(tmpl_rd_addr), .tmpl_rd_data(tmpl_rd_data),
        .tmpl_energy(tmpl_energy),
        .best_row(ncc_row), .best_col(ncc_col),
        .confidence(ncc_conf), .found_any(ncc_found)
    );

    kcf_top #(
        .N(PATCH_N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)
    ) u_kcf (
        .clk(clk), .rst_n(rst_n),
        .patch_addr(kcf_patch_addr),
        .patch_data(kcf_patch_data),
        .patch_wr_en(kcf_patch_wr_en),
        .detect_start(kcf_detect_start),
        .update_start(kcf_update_start),
        .alpha_wr_addr(12'd0), .alpha_wr_re({DATA_WIDTH{1'b0}}),
        .alpha_wr_im({DATA_WIDTH{1'b0}}), .alpha_wr_en(1'b0),
        .lambda(lambda),
        .peak_row(kcf_peak_row), .peak_col(kcf_peak_col),
        .peak_val(kcf_peak_val),
        .detect_done(kcf_detect_done), .update_done(kcf_update_done),
        .init_done(kcf_init_done)
    );

    track_ctrl #(
        .FRAME_W(FRAME_W), .FRAME_H(FRAME_H), .PATCH_N(PATCH_N), .DEC(DEC),
        .DATA_WIDTH(DATA_WIDTH), .AUTO_TINIT(AUTO_TINIT)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .mode(mode), .thresh(thresh), .kcf_thresh(kcf_thresh),
        .start_pend(start_pend), .tinit_pend(tinit_pend),
        .sreset_pulse(sreset_pulse),
        .frame_complete(frame_complete),
        .target_row(target_row), .target_col(target_col),
        .start_consume(start_consume), .tinit_consume(tinit_consume),
        .crop_req(crop_req), .crop_row(crop_row), .crop_col(crop_col),
        .crop_done(crop_done),
        .tinit_req(tinit_req), .tinit_done(tinit_done),
        .ncc_start(ncc_start), .ncc_done(ncc_done),
        .ncc_row(ncc_row), .ncc_col(ncc_col), .ncc_conf(ncc_conf),
        .kcf_detect_start(kcf_detect_start), .kcf_update_start(kcf_update_start),
        .kcf_detect_done(kcf_detect_done), .kcf_update_done(kcf_update_done),
        .kcf_peak_row(kcf_peak_row), .kcf_peak_col(kcf_peak_col),
        .kcf_peak_val(kcf_peak_val), .kcf_init_done(kcf_init_done),
        .stat_busy(stat_busy), .stat_done(stat_done),
        .stat_algo(stat_algo), .stat_tracking(stat_tracking), .stat_found(stat_found),
        .abs_row(abs_row), .abs_col(abs_col),
        .confidence(confidence), .irq_done(irq_done)
    );

    // ════════════════════════════════════════════════════════════════════
    //  OUTPUT SIDE — AXI read path, all register read-back
    // ════════════════════════════════════════════════════════════════════
    result_output_if #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_output (
        .clk(clk), .rst_n(rst_n),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .mode(mode), .thresh(thresh), .kcf_thresh(kcf_thresh), .lambda(lambda),
        .stat_busy(stat_busy), .stat_done(stat_done),
        .stat_algo(stat_algo), .stat_tracking(stat_tracking), .stat_found(stat_found),
        .abs_row(abs_row), .abs_col(abs_col),
        .confidence(confidence),
        .irq_mask(irq_mask), .irq_pending(irq_pending),
        .target_row(target_row), .target_col(target_col),
        .buf_idx(buf_idx)
    );

endmodule
