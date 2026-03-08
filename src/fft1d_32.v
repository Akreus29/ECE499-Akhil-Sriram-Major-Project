`timescale 1ns/1ps
// fft1d_32.v
// 32-point radix-2 DIT FFT, iterative single-butterfly architecture.
// log2(32) = 5 stages, 16 butterfly ops per stage = 80 cycles per transform.
// Uses scaled butterfly (>>>1 per stage) to prevent overflow.

module fft1d_32 #(
    parameter N          = 32,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8,
    parameter SCALE_EN   = 1    // 1 = >>>1 per stage (forward FFT), 0 = no scaling (IFFT)
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    input  wire signed [DATA_WIDTH-1:0]  in_re [0:N-1],
    input  wire signed [DATA_WIDTH-1:0]  in_im [0:N-1],
    output reg  signed [DATA_WIDTH-1:0]  out_re [0:N-1],
    output reg  signed [DATA_WIDTH-1:0]  out_im [0:N-1],
    output reg                           done
);

    // ── FSM states ──────────────────────────────────────────────────────
    localparam S_IDLE    = 3'd0;
    localparam S_BITREV  = 3'd1;
    localparam S_STAGE   = 3'd2;
    localparam S_OUTPUT  = 3'd3;
    localparam S_DONE    = 3'd4;

    reg [2:0] state;

    // ── Working buffer ──────────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] buf_re [0:N-1];
    reg signed [DATA_WIDTH-1:0] buf_im [0:N-1];

    // ── Stage counters ──────────────────────────────────────────────────
    reg [2:0]  stage_cnt;     // current FFT stage (0..4)
    reg [3:0]  bfly_cnt;      // butterfly index within stage (0..15)

    // ── Bit-reversal lookup (hardcoded for N=32, 5-bit reversal) ────────
    // bit_rev[i] = reverse of i's 5-bit binary representation
    function [4:0] bit_rev;
        input [4:0] idx;
        begin
            bit_rev = {idx[0], idx[1], idx[2], idx[3], idx[4]};
        end
    endfunction

    // ── Butterfly address computation ───────────────────────────────────
    // At stage s, butterflies operate on pairs separated by half = 2^s.
    // Group size = 2^(s+1). Number of groups = N / group.
    // For butterfly b (0..15):
    //   group_idx = b >> s         (which group)
    //   bfly_in_group = b & ((1<<s)-1)  (position within group)
    //   idx_a = group_idx * (2 << s) + bfly_in_group
    //   idx_b = idx_a + (1 << s)
    //   tw_addr = bfly_in_group * (N/2 >> s)

    wire [4:0] half  = 5'd1 << stage_cnt;         // 1, 2, 4, 8, 16
    wire [4:0] group = 5'd1 << (stage_cnt + 1);   // 2, 4, 8, 16, 32

    // Decompose bfly_cnt into group index and position within group
    wire [3:0] grp_idx;
    wire [3:0] bfly_in_grp;

    // grp_idx  = bfly_cnt >> stage_cnt
    // bfly_pos = bfly_cnt & (half - 1)
    assign grp_idx    = bfly_cnt >> stage_cnt;
    assign bfly_in_grp = bfly_cnt & (half[3:0] - 4'd1);

    wire [4:0] idx_a = grp_idx * group + bfly_in_grp;
    wire [4:0] idx_b = idx_a + half;

    // Twiddle address: k = bfly_in_grp * (N/2 / half) = bfly_in_grp << (4 - stage_cnt)
    wire [3:0] tw_addr = bfly_in_grp << (3'd4 - stage_cnt);

    // ── Twiddle ROM ─────────────────────────────────────────────────────
    wire signed [DATA_WIDTH-1:0] w_re, w_im;

    twiddle_rom_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_trom (
        .addr(tw_addr),
        .w_re(w_re),
        .w_im(w_im)
    );

    // ── Butterfly unit (combinational) ──────────────────────────────────
    wire signed [DATA_WIDTH-1:0] bf_out_re_a, bf_out_im_a;
    wire signed [DATA_WIDTH-1:0] bf_out_re_b, bf_out_im_b;

    butterfly #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC), .SCALE_EN(SCALE_EN)) u_bfly (
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
            done <= 0;   // default: de-assert

            case (state)

                S_IDLE: begin
                    if (start) begin
                        state <= S_BITREV;
                    end
                end

                // Load inputs into buffer in bit-reversed order (1 cycle)
                S_BITREV: begin
                    for (i = 0; i < N; i = i + 1) begin
                        buf_re[bit_rev(i[4:0])] <= in_re[i];
                        buf_im[bit_rev(i[4:0])] <= in_im[i];
                    end
                    stage_cnt <= 0;
                    bfly_cnt  <= 0;
                    state     <= S_STAGE;
                end

                // Execute one butterfly per clock cycle
                S_STAGE: begin
                    buf_re[idx_a] <= bf_out_re_a;
                    buf_im[idx_a] <= bf_out_im_a;
                    buf_re[idx_b] <= bf_out_re_b;
                    buf_im[idx_b] <= bf_out_im_b;

                    if (bfly_cnt == 4'd15) begin
                        // Finished all 16 butterflies in this stage
                        bfly_cnt <= 0;
                        if (stage_cnt == 3'd4) begin
                            // All 5 stages done
                            state <= S_OUTPUT;
                        end else begin
                            stage_cnt <= stage_cnt + 1;
                        end
                    end else begin
                        bfly_cnt <= bfly_cnt + 1;
                    end
                end

                // Copy buffer to outputs (1 cycle)
                S_OUTPUT: begin
                    for (i = 0; i < N; i = i + 1) begin
                        out_re[i] <= buf_re[i];
                        out_im[i] <= buf_im[i];
                    end
                    state <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1;
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule
