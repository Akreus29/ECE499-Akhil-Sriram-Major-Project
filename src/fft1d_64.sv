`timescale 1ns/1ps
// fft1d_64.sv
// 64-point radix-2 DIT FFT, iterative single-butterfly architecture.
// log2(64) = 6 stages, 32 butterfly ops per stage = 192 cycles per transform.
// Uses scaled butterfly (>>>1 per stage when scale_en=1) to prevent overflow.
//
// RESOURCE-FIXED VERSION: the old out_re/out_im output arrays and the
// parallel S_OUTPUT copy state are removed — they were pure 1-cycle copies
// of the working buffer costing ~4K flip-flops plus wide muxes per instance.
// Results are instead read through a combinational read port
// (out_rd_addr → out_rd_re/out_rd_im) directly from the working buffer,
// which is stable from `done` until the next start.

module fft1d_64 #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    input  wire                          scale_en,   // 1 = >>>1 per stage, 0 = no scaling
    input  wire signed [DATA_WIDTH-1:0]  in_re [0:N-1],
    input  wire signed [DATA_WIDTH-1:0]  in_im [0:N-1],
    // Result read port (combinational; valid from done until next start)
    input  wire [5:0]                    out_rd_addr,
    output wire signed [DATA_WIDTH-1:0]  out_rd_re,
    output wire signed [DATA_WIDTH-1:0]  out_rd_im,
    output reg                           done
);

    // ── FSM states ──────────────────────────────────────────────────────
    localparam S_IDLE   = 3'd0;
    localparam S_BITREV = 3'd1;
    localparam S_STAGE  = 3'd2;
    localparam S_DONE   = 3'd3;

    reg [2:0] state;

    // ── Working buffer ──────────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] buf_re [0:N-1];
    reg signed [DATA_WIDTH-1:0] buf_im [0:N-1];

    // Result read port — combinational view into the working buffer
    assign out_rd_re = buf_re[out_rd_addr];
    assign out_rd_im = buf_im[out_rd_addr];

    // ── Stage / butterfly counters ──────────────────────────────────────
    reg [2:0] stage_cnt;    // 0..5 (6 stages)
    reg [4:0] bfly_cnt;     // 0..31 (32 butterflies per stage)

    // ── Bit-reversal (6-bit indices for N=64) ───────────────────────────
    function [5:0] bit_rev;
        input [5:0] idx;
        begin
            bit_rev = {idx[0], idx[1], idx[2], idx[3], idx[4], idx[5]};
        end
    endfunction

    // ── Butterfly address computation ───────────────────────────────────
    // half  = 2^stage_cnt  (1,2,4,8,16,32)
    // group = 2^(stage_cnt+1)
    // grp_idx     = bfly_cnt >> stage_cnt
    // bfly_in_grp = bfly_cnt & (half - 1)
    // idx_a = grp_idx * group + bfly_in_grp
    // idx_b = idx_a + half
    // tw_addr = bfly_in_grp << (5 - stage_cnt)   [W_64^k, k = addr]

    wire [5:0] half  = 6'd1 << stage_cnt;
    wire [6:0] group = 7'd1 << (stage_cnt + 1);

    wire [4:0] grp_idx     = bfly_cnt >> stage_cnt;
    wire [4:0] bfly_in_grp = bfly_cnt & (half[4:0] - 5'd1);

    wire [5:0] idx_a = grp_idx * group[5:0] + bfly_in_grp;
    wire [5:0] idx_b = idx_a + half;

    // Twiddle address: k = bfly_in_grp * (N/2 / half) = bfly_in_grp << (5 - stage_cnt)
    wire [4:0] tw_addr = bfly_in_grp << (3'd5 - stage_cnt);

    // ── Twiddle ROM ─────────────────────────────────────────────────────
    wire signed [DATA_WIDTH-1:0] w_re, w_im;

    twiddle_rom #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_trom (
        .addr(tw_addr),
        .w_re(w_re),
        .w_im(w_im)
    );

    // ── Butterfly unit (combinational) ──────────────────────────────────
    wire signed [DATA_WIDTH-1:0] bf_out_re_a, bf_out_im_a;
    wire signed [DATA_WIDTH-1:0] bf_out_re_b, bf_out_im_b;

    butterfly #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_bfly (
        .scale_en(scale_en),
        .in_re_a(buf_re[idx_a]), .in_im_a(buf_im[idx_a]),
        .in_re_b(buf_re[idx_b]), .in_im_b(buf_im[idx_b]),
        .w_re(w_re),             .w_im(w_im),
        .out_re_a(bf_out_re_a),  .out_im_a(bf_out_im_a),
        .out_re_b(bf_out_re_b),  .out_im_b(bf_out_im_b)
    );

    // ── Main FSM ────────────────────────────────────────────────────────
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            stage_cnt <= 0;
            bfly_cnt  <= 0;
            done      <= 0;
        end else begin
            done <= 0;

            case (state)

                S_IDLE: begin
                    if (start) state <= S_BITREV;
                end

                // Load inputs in bit-reversed order (1 cycle)
                S_BITREV: begin
                    for (i = 0; i < N; i = i + 1) begin
                        buf_re[bit_rev(i[5:0])] <= in_re[i];
                        buf_im[bit_rev(i[5:0])] <= in_im[i];
                    end
                    stage_cnt <= 0;
                    bfly_cnt  <= 0;
                    state     <= S_STAGE;
                end

                // One butterfly per clock cycle
                S_STAGE: begin
                    buf_re[idx_a] <= bf_out_re_a;
                    buf_im[idx_a] <= bf_out_im_a;
                    buf_re[idx_b] <= bf_out_re_b;
                    buf_im[idx_b] <= bf_out_im_b;

                    if (bfly_cnt == 5'd31) begin
                        bfly_cnt <= 0;
                        if (stage_cnt == 3'd5) begin
                            state <= S_DONE;   // results readable via out_rd port
                        end else begin
                            stage_cnt <= stage_cnt + 1;
                        end
                    end else begin
                        bfly_cnt <= bfly_cnt + 1;
                    end
                end

                S_DONE: begin
                    done  <= 1;
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule
