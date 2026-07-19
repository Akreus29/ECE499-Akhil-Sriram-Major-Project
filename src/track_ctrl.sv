`timescale 1ns/1ps
// =============================================================================
// track_ctrl.sv
// Top-level tracking controller: NCC acquisition → KCF lock → loss fallback.
//
// Modes (mode[1:0]):
//   0 AUTO — full-frame NCC acquisition each frame until confidence ≥ THRESH,
//            then IMMEDIATE switch to KCF in the same frame (crop at the NCC
//            centre).  While tracking, frames go straight to KCF at the
//            last-known centre.  If KCF confidence < THRESH for LOSS_FRAMES
//            consecutive frames, tracking drops and NCC re-acquires.
//   1 NCC only — full-frame NCC every frame, never switches.
//   2 KCF only — KCF at the last/seeded centre every frame (no fallback).
//
// Target designation (CTRL.target_init, requires a complete uploaded frame):
//   frame_input_if crops 64×64 at TARGET_POS → builds the NCC template AND
//   feeds the crop to kcf_top; this FSM then runs kcf detect (captures X̂,
//   result discarded) + update (pre-trains α).  Centre ← TARGET_POS.
//
// KCF displacement decode (DFT-centred response): peak p ∈ 0..63 →
//   d = (p ≤ 32) ? p : p − 64,  new centre = old + d, clamped to [32, 288].
//
// Coordinate mapping from NCC (decimated window top-left (y,x), DEC=4):
//   full-res centre = 4·y + 32 , 4·x + 32.
// =============================================================================

module track_ctrl #(
    parameter FRAME_W     = 320,
    parameter FRAME_H     = 240,
    parameter PATCH_N     = 64,
    parameter DEC         = 4,
    parameter DATA_WIDTH  = 16,
    parameter LOSS_FRAMES = 3,
    // ICD v3.1: run the designation sequence automatically at boot using the
    // preloaded frame BRAM + baked TARGET_POS — runtime needs no designation
    parameter AUTO_TINIT  = 1
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // ── From frame_input_if: config + commands ──────────────────────────
    input  wire [1:0]                    mode,
    input  wire signed [DATA_WIDTH-1:0]  thresh,         // NCC² acquisition threshold
    input  wire signed [DATA_WIDTH-1:0]  kcf_thresh,     // KCF loss threshold (0 = off)
    input  wire                          start_pend,     // level: CTRL.start latched
    input  wire                          tinit_pend,     // level: CTRL.target_init latched
    input  wire                          sreset_pulse,   // CTRL.soft_reset
    input  wire                          frame_complete, // buf_index_counter full
    input  wire [8:0]                    target_row,     // TARGET_POS (designation)
    input  wire [8:0]                    target_col,
    output reg                           start_consume,  // 1-cycle: command accepted
    output reg                           tinit_consume,

    // ── To frame_input_if: engines ──────────────────────────────────────
    output reg                           crop_req,       // pulse: feed 64×64 at (crop_row,col)
    output reg  [8:0]                    crop_row,
    output reg  [8:0]                    crop_col,
    input  wire                          crop_done,
    output reg                           tinit_req,      // pulse: template build + kcf feed
    input  wire                          tinit_done,

    // ── ncc_search ──────────────────────────────────────────────────────
    output reg                           ncc_start,
    input  wire                          ncc_done,
    input  wire [6:0]                    ncc_row,        // decimated window top-left
    input  wire [6:0]                    ncc_col,
    input  wire [15:0]                   ncc_conf,       // Q8.8 NCC²

    // ── kcf_top ─────────────────────────────────────────────────────────
    output reg                           kcf_detect_start,
    output reg                           kcf_update_start,
    input  wire                          kcf_detect_done,
    input  wire                          kcf_update_done,
    input  wire [5:0]                    kcf_peak_row,
    input  wire [5:0]                    kcf_peak_col,
    input  wire signed [DATA_WIDTH-1:0]  kcf_peak_val,
    input  wire                          kcf_init_done,  // Y_hat self-init pulse

    // ── Status / results (to result_output_if) ──────────────────────────
    output reg                           stat_busy,
    output reg                           stat_done,      // latched
    output reg  [1:0]                    stat_algo,      // 0=NCC, 1=KCF
    output reg                           stat_tracking,
    output reg                           stat_found,     // uniform: target located
    output reg  [8:0]                    abs_row,        // absolute centre 0..239
    output reg  [8:0]                    abs_col,        // absolute centre 0..319
    output reg  signed [DATA_WIDTH-1:0]  confidence,
    output reg                           irq_done        // 1-cycle pulse per result
);

    localparam MODE_AUTO = 2'd0;
    localparam MODE_NCC  = 2'd1;
    localparam MODE_KCF  = 2'd2;

    localparam C_MIN   = PATCH_N/2;             // 32
    localparam C_MAX_R = FRAME_H - PATCH_N/2;   // 208 (240-row frame)
    localparam C_MAX_C = FRAME_W - PATCH_N/2;   // 288

    localparam S_WAIT_KCF = 4'd0;   // wait for kcf Y_hat self-init
    localparam S_IDLE     = 4'd1;
    localparam S_TI_CROP  = 4'd2;   // designation: template + kcf feed
    localparam S_TI_DET   = 4'd3;   // designation: capture X_hat
    localparam S_TI_UPD   = 4'd4;   // designation: pre-train alpha
    localparam S_NCC_RUN  = 4'd5;
    localparam S_CROP     = 4'd6;
    localparam S_KCF_DET  = 4'd7;
    localparam S_KCF_UPD  = 4'd8;
    localparam S_REPORT   = 4'd9;

    reg [3:0] state;

    reg [8:0]  centre_row, centre_col;   // last-known target centre
    reg [1:0]  loss_cnt;
    reg [1:0]  report_algo;
    reg        report_found;             // "target located" for this result
    reg        kcf_ready;                // latched init_done

    // Per-axis clamp helpers (combinational)
    function [8:0] clamp_r;   // row axis: [32, 208]
        input [9:0] v;
        begin
            if (v < C_MIN[9:0])          clamp_r = C_MIN[8:0];
            else if (v > C_MAX_R[9:0])   clamp_r = C_MAX_R[8:0];
            else                         clamp_r = v[8:0];
        end
    endfunction

    function [8:0] clamp_c;   // col axis: [32, 288]
        input [9:0] v;
        begin
            if (v < C_MIN[9:0])          clamp_c = C_MIN[8:0];
            else if (v > C_MAX_C[9:0])   clamp_c = C_MAX_C[8:0];
            else                         clamp_c = v[8:0];
        end
    endfunction

    // KCF displacement decode (signed, ±32 max)
    wire signed [6:0] disp_r = (kcf_peak_row <= 6'd32)
                             ? {1'b0, kcf_peak_row}
                             : {1'b0, kcf_peak_row} - 7'sd64;
    wire signed [6:0] disp_c = (kcf_peak_col <= 6'd32)
                             ? {1'b0, kcf_peak_col}
                             : {1'b0, kcf_peak_col} - 7'sd64;

    // New centre (10-bit intermediate to catch clamping range)
    wire [9:0] new_row = {1'b0, centre_row} + {{3{disp_r[6]}}, disp_r};
    wire [9:0] new_col = {1'b0, centre_col} + {{3{disp_c[6]}}, disp_c};

    // NCC decimated window top-left → full-res centre: 4·y + 32
    wire [9:0] ncc_centre_row = ({3'd0, ncc_row} << 2) + 10'd32;
    wire [9:0] ncc_centre_col = ({3'd0, ncc_col} << 2) + 10'd32;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_WAIT_KCF;
            start_consume    <= 1'b0;
            tinit_consume    <= 1'b0;
            crop_req         <= 1'b0;
            crop_row         <= 9'd120;
            crop_col         <= 9'd160;
            tinit_req        <= 1'b0;
            ncc_start        <= 1'b0;
            kcf_detect_start <= 1'b0;
            kcf_update_start <= 1'b0;
            stat_busy        <= 1'b0;
            stat_done        <= 1'b0;
            stat_algo        <= 2'd0;
            stat_tracking    <= 1'b0;
            stat_found       <= 1'b0;
            abs_row          <= 9'd0;
            abs_col          <= 9'd0;
            confidence       <= {DATA_WIDTH{1'b0}};
            irq_done         <= 1'b0;
            centre_row       <= 9'd120;
            centre_col       <= 9'd160;
            loss_cnt         <= 2'd0;
            report_algo      <= 2'd0;
            report_found     <= 1'b0;
            kcf_ready        <= 1'b0;
        end else begin
            // Pulse defaults
            start_consume    <= 1'b0;
            tinit_consume    <= 1'b0;
            crop_req         <= 1'b0;
            tinit_req        <= 1'b0;
            ncc_start        <= 1'b0;
            kcf_detect_start <= 1'b0;
            kcf_update_start <= 1'b0;
            irq_done         <= 1'b0;

            if (kcf_init_done)
                kcf_ready <= 1'b1;

            // Soft reset: clear done (pending flags cleared in frame_input_if)
            if (sreset_pulse)
                stat_done <= 1'b0;

            case (state)

                S_WAIT_KCF: begin
                    if (kcf_ready || kcf_init_done) begin
                        if (AUTO_TINIT != 0) begin
                            // Boot designation from the preloaded frame:
                            // crop at the baked TARGET_POS, build the NCC
                            // template, pre-train KCF — then STATUS.done=1
                            // tells software the tracker is ready.
                            stat_busy <= 1'b1;
                            tinit_req <= 1'b1;
                            state     <= S_TI_CROP;
                        end else
                            state <= S_IDLE;
                    end
                end

                S_IDLE: begin
                    if (tinit_pend && frame_complete) begin
                        tinit_consume <= 1'b1;
                        stat_busy     <= 1'b1;
                        stat_done     <= 1'b0;
                        tinit_req     <= 1'b1;
                        state         <= S_TI_CROP;
                    end else if (start_pend && frame_complete) begin
                        start_consume <= 1'b1;
                        stat_busy     <= 1'b1;
                        stat_done     <= 1'b0;
                        if (mode == MODE_KCF ||
                            (mode == MODE_AUTO && stat_tracking)) begin
                            crop_req <= 1'b1;
                            crop_row <= centre_row;
                            crop_col <= centre_col;
                            state    <= S_CROP;
                        end else begin
                            ncc_start <= 1'b1;
                            state     <= S_NCC_RUN;
                        end
                    end
                end

                // ──────────── Target designation ────────────────────────
                S_TI_CROP: begin
                    if (tinit_done) begin
                        kcf_detect_start <= 1'b1;
                        state            <= S_TI_DET;
                    end
                end

                S_TI_DET: begin
                    // Detection result discarded — only captures X_hat
                    if (kcf_detect_done) begin
                        kcf_update_start <= 1'b1;
                        state            <= S_TI_UPD;
                    end
                end

                S_TI_UPD: begin
                    if (kcf_update_done) begin
                        centre_row    <= clamp_r({1'b0, target_row});
                        centre_col    <= clamp_c({1'b0, target_col});
                        stat_tracking <= 1'b0;   // runtime starts with NCC
                        stat_found    <= 1'b0;   // designation, not a detection
                        loss_cnt      <= 2'd0;
                        stat_busy     <= 1'b0;
                        stat_done     <= 1'b1;   // designation complete
                        irq_done      <= 1'b1;
                        state         <= S_IDLE;
                    end
                end

                // ──────────── NCC full-frame acquisition ────────────────
                S_NCC_RUN: begin
                    if (ncc_done) begin
                        abs_row    <= clamp_r(ncc_centre_row);
                        abs_col    <= clamp_c(ncc_centre_col);
                        confidence <= $signed(ncc_conf);

                        if (mode == MODE_AUTO &&
                            $signed({1'b0, ncc_conf}) >= $signed(thresh)) begin
                            // Acquired — IMMEDIATE switch to KCF, same frame
                            stat_tracking <= 1'b1;
                            loss_cnt      <= 2'd0;
                            centre_row    <= clamp_r(ncc_centre_row);
                            centre_col    <= clamp_c(ncc_centre_col);
                            crop_req      <= 1'b1;
                            crop_row      <= clamp_r(ncc_centre_row);
                            crop_col      <= clamp_c(ncc_centre_col);
                            state         <= S_CROP;
                        end else begin
                            report_algo  <= 2'd0;   // NCC result
                            report_found <= ($signed({1'b0, ncc_conf})
                                             >= $signed(thresh));
                            state        <= S_REPORT;
                        end
                    end
                end

                // ──────────── KCF crop tracking ─────────────────────────
                S_CROP: begin
                    if (crop_done) begin
                        kcf_detect_start <= 1'b1;
                        state            <= S_KCF_DET;
                    end
                end

                S_KCF_DET: begin
                    if (kcf_detect_done) begin
                        centre_row <= clamp_r(new_row);
                        centre_col <= clamp_c(new_col);
                        abs_row    <= clamp_r(new_row);
                        abs_col    <= clamp_c(new_col);
                        confidence <= kcf_peak_val;

                        // Loss detection (AUTO mode only; KCF_THRESH scale —
                        // KCF peak values are far smaller than NCC² scores.
                        // kcf_thresh = 0 disables fallback: peaks are ≥ 0)
                        if (mode == MODE_AUTO &&
                            $signed(kcf_peak_val) < $signed(kcf_thresh)) begin
                            if (loss_cnt == LOSS_FRAMES[1:0] - 2'd1) begin
                                stat_tracking <= 1'b0;   // fall back to NCC
                                loss_cnt      <= 2'd0;
                            end else
                                loss_cnt <= loss_cnt + 2'd1;
                            // SKIP the filter update on loss-counted frames:
                            // adapting on a target-less crop would train the
                            // filter onto the background, which then
                            // self-matches with high confidence and defeats
                            // loss detection entirely.
                            report_algo  <= 2'd1;
                            report_found <= 1'b0;       // below loss threshold
                            state        <= S_REPORT;
                        end else begin
                            if (mode == MODE_AUTO)
                                loss_cnt <= 2'd0;
                            report_found     <= 1'b1;   // KCF lock is valid
                            kcf_update_start <= 1'b1;   // per-frame adaptation
                            state            <= S_KCF_UPD;
                        end
                    end
                end

                S_KCF_UPD: begin
                    if (kcf_update_done) begin
                        report_algo <= 2'd1;   // KCF result
                        state       <= S_REPORT;
                    end
                end

                // ──────────── Publish result ────────────────────────────
                S_REPORT: begin
                    stat_algo  <= report_algo;
                    stat_found <= report_found;
                    stat_busy  <= 1'b0;
                    stat_done  <= 1'b1;
                    irq_done  <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
