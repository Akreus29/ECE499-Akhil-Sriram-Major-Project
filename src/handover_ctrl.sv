`timescale 1ns/1ps
// handover_ctrl.sv
// Algorithm-selection and handover controller.
//
// Modes (mode[1:0]):
//   2'd0 AUTO — start with NCC; permanently hand over to KCF when NCC confidence
//               falls below `thresh` for MIN_KCF_FRAMES consecutive frames.
//   2'd1 NCC  — force NCC only
//   2'd2 KCF  — force KCF only (requires prior alpha to be initialised)
//
// Handover is one-way in AUTO: once KCF is active it never reverts to NCC.
// algo_select: 0 = NCC result, 1 = KCF result.
//
// Caller writes patch data into ncc_top and kcf_top before asserting frame_valid.

module handover_ctrl #(
    parameter LOG2N          = 6,    // $clog2(N); 6 for N=64
    parameter DATA_WIDTH     = 16,
    parameter FRAC           = 8,
    parameter MIN_KCF_FRAMES = 3     // consecutive low-confidence NCC frames → handover
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // Global control
    input  wire [1:0]                 mode,        // 0=AUTO, 1=NCC, 2=KCF
    input  wire signed [DATA_WIDTH-1:0] thresh,    // NCC→KCF threshold Q8.8
    input  wire                       frame_valid, // pulse: patch ready, start processing

    // NCC tracker interface
    input  wire                       ncc_done,
    input  wire signed [DATA_WIDTH-1:0] ncc_score,
    input  wire [LOG2N-1:0]           ncc_row,
    input  wire [LOG2N-1:0]           ncc_col,
    output reg                        ncc_start,

    // KCF tracker interface
    input  wire                       kcf_detect_done,
    input  wire                       kcf_update_done,
    input  wire signed [DATA_WIDTH-1:0] kcf_score,
    input  wire [LOG2N-1:0]           kcf_row,
    input  wire [LOG2N-1:0]           kcf_col,
    output reg                        kcf_detect_start,
    output reg                        kcf_update_start,

    // Selected tracking result
    output reg  [LOG2N-1:0]           out_row,
    output reg  [LOG2N-1:0]           out_col,
    output reg  signed [DATA_WIDTH-1:0] out_conf,
    output reg                        result_valid,
    output reg                        algo_select   // 0=NCC, 1=KCF
);

    localparam MODE_AUTO = 2'd0;
    localparam MODE_NCC  = 2'd1;
    localparam MODE_KCF  = 2'd2;

    localparam S_IDLE      = 3'd0;
    localparam S_NCC_WAIT  = 3'd1;
    localparam S_KCF_WAIT  = 3'd2;
    localparam S_KCF_UPD_W = 3'd3;
    localparam S_RESULT    = 3'd4;

    reg [2:0] state;

    // Handover state: counts consecutive low-confidence NCC frames
    reg [2:0]  low_conf_cnt;   // 3 bits covers MIN_KCF_FRAMES up to 7
    reg        in_kcf_mode;    // latched high once AUTO handover fires

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            ncc_start        <= 0;
            kcf_detect_start <= 0;
            kcf_update_start <= 0;
            result_valid     <= 0;
            algo_select      <= 0;
            low_conf_cnt     <= 0;
            in_kcf_mode      <= 0;
            out_row          <= 0;
            out_col          <= 0;
            out_conf         <= 0;
        end else begin
            ncc_start        <= 0;
            kcf_detect_start <= 0;
            kcf_update_start <= 0;
            result_valid     <= 0;

            case (state)

                S_IDLE: begin
                    if (frame_valid) begin
                        // Decide which tracker to use this frame
                        if (mode == MODE_KCF || (mode == MODE_AUTO && in_kcf_mode)) begin
                            kcf_detect_start <= 1;
                            state            <= S_KCF_WAIT;
                        end else begin
                            ncc_start <= 1;
                            state     <= S_NCC_WAIT;
                        end
                    end
                end

                // ── NCC path ───────────────────────────────────────────────
                S_NCC_WAIT: begin
                    if (ncc_done) begin
                        out_row     <= ncc_row;
                        out_col     <= ncc_col;
                        out_conf    <= ncc_score;
                        algo_select <= 0;

                        if (mode == MODE_AUTO) begin
                            if ($signed(ncc_score) < $signed(thresh)) begin
                                if (low_conf_cnt >= MIN_KCF_FRAMES - 1) begin
                                    in_kcf_mode  <= 1;
                                    low_conf_cnt <= 0;
                                end else begin
                                    low_conf_cnt <= low_conf_cnt + 1;
                                end
                            end else begin
                                low_conf_cnt <= 0;
                            end
                        end

                        state <= S_RESULT;
                    end
                end

                // ── KCF path ───────────────────────────────────────────────
                S_KCF_WAIT: begin
                    if (kcf_detect_done) begin
                        out_row          <= kcf_row;
                        out_col          <= kcf_col;
                        out_conf         <= kcf_score;
                        algo_select      <= 1;
                        kcf_update_start <= 1;
                        state            <= S_KCF_UPD_W;
                    end
                end

                S_KCF_UPD_W: begin
                    if (kcf_update_done) state <= S_RESULT;
                end

                // ── Output result ──────────────────────────────────────────
                S_RESULT: begin
                    result_valid <= 1;
                    state        <= S_IDLE;
                end

            endcase
        end
    end

endmodule
