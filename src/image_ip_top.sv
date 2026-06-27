`timescale 1ns/1ps
// image_ip_top.sv
// Top-level datapath for the KCF/NCC image-processing IP.
// No AXI signals — register-level I/O only.  AXI wrappers are in image_ip_axilite.sv.
//
// Sub-modules instantiated:
//   axi_stream_patch_buf — AXI4-Stream receiver → patch / template write ports
//   ncc_top              — NCC cross-correlation tracker
//   kcf_top              — KCF Wiener-filter tracker
//   handover_ctrl        — algorithm selection and NCC → KCF handover logic
//
// Reset sequence:
//   After rst_n de-assertion, kcf_top self-initialises Y_hat (~4096 + FFT2D cycles).
//   kcf_init_done pulses when ready.  Software should wait for the STATUS.busy=0
//   before issuing the first template_init command.
//
// Template init sequence (CTRL[4]=1, CTRL[2]=1):
//   1. DMA streams template packet (TUSER=1) via AXI-Stream.
//   2. axi_stream_patch_buf raises tmpl_ready_pulse.
//   3. image_ip_top asserts ncc_top.tmpl_init → ncc_top computes FFT(template).
//   4. ncc_top.tmpl_ready goes high when done.
//
// Normal tracking (CTRL[2]=1):
//   1. DMA streams search patch (TUSER=0).
//   2. axi_stream_patch_buf raises patch_ready_pulse.
//   3. handover_ctrl decides NCC or KCF and fires detect start.
//   4. On result_valid: out_row / out_col / out_conf / algo_select are latched.
//   5. STATUS.done goes high; irq_done pulses.

module image_ip_top #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                           clk,
    input  wire                           rst_n,

    // AXI4-Stream slave (from DMA)
    input  wire [DATA_WIDTH-1:0]          s_axis_tdata,
    input  wire                           s_axis_tvalid,
    output wire                           s_axis_tready,
    input  wire                           s_axis_tlast,
    input  wire                           s_axis_tuser,   // 0=patch, 1=template

    // Control register inputs (from AXI-Lite wrapper)
    input  wire [1:0]                     ctrl_mode,       // 0=AUTO, 1=NCC, 2=KCF
    input  wire                           ctrl_start,      // pulse: start detection
    input  wire                           ctrl_soft_reset, // pulse: clear done flag
    input  wire                           ctrl_tmpl_init,  // pulse: init NCC template
    input  wire signed [DATA_WIDTH-1:0]   ctrl_thresh,     // NCC→KCF handover threshold
    input  wire signed [DATA_WIDTH-1:0]   ctrl_lambda,     // KCF regularisation

    // Status outputs (to AXI-Lite wrapper)
    output reg                            stat_busy,
    output reg                            stat_done,
    output reg  [1:0]                     stat_algo,       // 0=NCC, 1=KCF
    output reg                            stat_stream_active,
    output reg  [$clog2(N)-1:0]           stat_peak_row,
    output reg  [$clog2(N)-1:0]           stat_peak_col,
    output reg  signed [DATA_WIDTH-1:0]   stat_confidence,
    output reg                            irq_done         // 1-cycle pulse to PLIC
);

    localparam LOG2N = $clog2(N);   // 6 for N=64

    // ── AXI-Stream patch buffer ─────────────────────────────────────────────
    wire [$clog2(N*N)-1:0]         axis_wr_addr;
    wire signed [DATA_WIDTH-1:0]   axis_wr_data;
    wire                           axis_patch_wr_en;
    wire                           axis_tmpl_wr_en;
    wire                           axis_patch_ready;
    wire                           axis_tmpl_ready;

    axi_stream_patch_buf #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_axis_buf (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),   .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .s_axis_tuser(s_axis_tuser),
        .wr_addr(axis_wr_addr),        .wr_data(axis_wr_data),
        .patch_wr_en(axis_patch_wr_en),.tmpl_wr_en(axis_tmpl_wr_en),
        .patch_ready(axis_patch_ready),.tmpl_ready(axis_tmpl_ready)
    );

    assign stat_stream_active = s_axis_tvalid;

    // ── NCC tracker ─────────────────────────────────────────────────────────
    wire                        ncc_tmpl_ready;
    wire [LOG2N-1:0]            ncc_peak_row, ncc_peak_col;
    wire signed [DATA_WIDTH-1:0] ncc_score;
    wire                        ncc_done;
    reg                         ncc_start_r;
    reg                         ncc_tmpl_init_r;

    ncc_top #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_ncc (
        .clk(clk), .rst_n(rst_n),
        // Template write: driven by AXI-Stream buffer (TUSER=1) or ctrl_tmpl_init
        .tmpl_wr_addr(axis_wr_addr),   .tmpl_wr_data(axis_wr_data),
        .tmpl_wr_en(axis_tmpl_wr_en),
        .tmpl_init(ncc_tmpl_init_r),   .tmpl_ready(ncc_tmpl_ready),
        // Patch write: driven by AXI-Stream buffer (TUSER=0)
        .patch_addr(axis_wr_addr),     .patch_data(axis_wr_data),
        .patch_wr_en(axis_patch_wr_en),
        .start(ncc_start_r),
        .peak_row(ncc_peak_row), .peak_col(ncc_peak_col),
        .ncc_score(ncc_score),   .done(ncc_done)
    );

    // ── KCF tracker ─────────────────────────────────────────────────────────
    wire [LOG2N-1:0]              kcf_peak_row, kcf_peak_col;
    wire signed [DATA_WIDTH-1:0]  kcf_score;
    wire                          kcf_detect_done_w, kcf_update_done_w;
    wire                          kcf_init_done;
    reg                           kcf_detect_start_r, kcf_update_start_r;

    kcf_top #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_kcf (
        .clk(clk), .rst_n(rst_n),
        // Patch write: same write bus as NCC
        .patch_addr(axis_wr_addr),      .patch_data(axis_wr_data),
        .patch_wr_en(axis_patch_wr_en),
        .detect_start(kcf_detect_start_r),
        .update_start(kcf_update_start_r),
        // No external alpha init needed in normal operation
        .alpha_wr_addr(0), .alpha_wr_re(0), .alpha_wr_im(0), .alpha_wr_en(0),
        .lambda(ctrl_lambda),
        .peak_row(kcf_peak_row),         .peak_col(kcf_peak_col),
        .peak_val(kcf_score),
        .detect_done(kcf_detect_done_w), .update_done(kcf_update_done_w),
        .init_done(kcf_init_done)
    );

    // ── Handover controller ──────────────────────────────────────────────────
    wire [LOG2N-1:0]              hc_row, hc_col;
    wire signed [DATA_WIDTH-1:0]  hc_conf;
    wire                          hc_result_valid;
    wire                          hc_algo_select;
    wire                          hc_ncc_start;
    wire                          hc_kcf_detect_start;
    wire                          hc_kcf_update_start;
    reg                           hc_frame_valid;

    handover_ctrl #(.LOG2N(LOG2N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_hc (
        .clk(clk), .rst_n(rst_n),
        .mode(ctrl_mode),         .thresh(ctrl_thresh),
        .frame_valid(hc_frame_valid),
        .ncc_done(ncc_done),      .ncc_score(ncc_score),
        .ncc_row(ncc_peak_row),   .ncc_col(ncc_peak_col),
        .ncc_start(hc_ncc_start),
        .kcf_detect_done(kcf_detect_done_w), .kcf_update_done(kcf_update_done_w),
        .kcf_score(kcf_score),
        .kcf_row(kcf_peak_row),   .kcf_col(kcf_peak_col),
        .kcf_detect_start(hc_kcf_detect_start),
        .kcf_update_start(hc_kcf_update_start),
        .out_row(hc_row),         .out_col(hc_col),
        .out_conf(hc_conf),       .result_valid(hc_result_valid),
        .algo_select(hc_algo_select)
    );

    // Route handover controller start signals to tracker regs
    always @(*) begin
        ncc_start_r        = hc_ncc_start;
        kcf_detect_start_r = hc_kcf_detect_start;
        kcf_update_start_r = hc_kcf_update_start;
        ncc_tmpl_init_r    = ctrl_tmpl_init | axis_tmpl_ready;
    end

    // ── Control / Status FSM ────────────────────────────────────────────────
    // Combinational logic feeds handover controller; status registers update on result
    reg prev_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_busy       <= 0;
            stat_done       <= 0;
            stat_algo       <= 0;
            stat_peak_row   <= 0;
            stat_peak_col   <= 0;
            stat_confidence <= 0;
            irq_done        <= 0;
            hc_frame_valid  <= 0;
            prev_done       <= 0;
        end else begin
            irq_done       <= 0;
            hc_frame_valid <= 0;

            // Clear done on soft reset or new start
            if (ctrl_soft_reset)
                stat_done <= 0;

            // Launch handover controller when patch arrives and ctrl_start is set
            if (axis_patch_ready && ctrl_start) begin
                hc_frame_valid <= 1;
                stat_busy      <= 1;
                stat_done      <= 0;
            end

            // Latch results when handover controller produces a valid output
            if (hc_result_valid) begin
                stat_peak_row   <= hc_row;
                stat_peak_col   <= hc_col;
                stat_confidence <= hc_conf;
                stat_algo       <= {1'b0, hc_algo_select};
                stat_busy       <= 0;
                stat_done       <= 1;
            end

            // Pulse IRQ on done rising edge
            prev_done <= stat_done;
            if (stat_done && !prev_done)
                irq_done <= 1;
        end
    end

endmodule
