`timescale 1ns/1ps
// ncc_top.sv
// 64×64 NCC (cross-correlation) tracker.
//
// Two-phase operation:
//   tmpl_init pulse  — apply 2D Hann window to stored template pixels, compute FFT2D,
//                      save result to internal freq-domain reference (alpha_re/im).
//                      tmpl_ready goes high when complete.
//
//   start pulse (requires tmpl_ready=1)
//                    — Hann-window search patch, FFT2D, element-wise
//                      conj(FFT(template)) * FFT(patch), IFFT2D, peak finder.
//                      ncc_score = raw correlation peak value (Q8.8).
//
// Note: both patch and template are Hann-windowed before FFT to reduce spectral
// leakage. The 2D Hann coefficient is computed as hann[row] * hann[col] in Q8.8.

module ncc_top #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                           clk,
    input  wire                           rst_n,

    // Template pixel write + init
    input  wire [$clog2(N*N)-1:0]         tmpl_wr_addr,
    input  wire signed [DATA_WIDTH-1:0]   tmpl_wr_data,
    input  wire                           tmpl_wr_en,
    input  wire                           tmpl_init,   // pulse: triggers Hann+FFT of template
    output reg                            tmpl_ready,  // high when template FFT is valid

    // Search patch write + start
    input  wire [$clog2(N*N)-1:0]         patch_addr,
    input  wire signed [DATA_WIDTH-1:0]   patch_data,
    input  wire                           patch_wr_en,
    input  wire                           start,

    // Results
    output reg  [$clog2(N)-1:0]           peak_row,
    output reg  [$clog2(N)-1:0]           peak_col,
    output reg  signed [DATA_WIDTH-1:0]   ncc_score,
    output reg                            done
);

    localparam TOTAL = N * N;    // 4096

    localparam S_IDLE         = 4'd0;
    localparam S_TMPL_FFT_LD  = 4'd1;
    localparam S_TMPL_FFT_RUN = 4'd2;
    localparam S_TMPL_SAVE    = 4'd3;
    localparam S_PATCH_FFT_LD = 4'd4;
    localparam S_PATCH_FFT_RN = 4'd5;
    localparam S_ELEM_MUL     = 4'd6;
    localparam S_IFFT_LOAD    = 4'd7;
    localparam S_IFFT_RUN     = 4'd8;
    localparam S_PEAK_RUN     = 4'd9;
    localparam S_DONE         = 4'd10;

    reg [3:0]  state;
    reg [12:0] cnt;    // 0..4096 (need 13 bits for PEAK_RUN flush)

    // Raw pixel buffers
    reg signed [DATA_WIDTH-1:0] tmpl_buf  [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] patch_buf [0:TOTAL-1];

    // Frequency-domain template: FFT(Hann * template), un-conjugated.
    // cconj_mul conjugates the b-port at runtime during ELEM_MUL.
    reg signed [DATA_WIDTH-1:0] alpha_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_im [0:TOTAL-1];

    // 2D Hann address decode (N=64 is a power of 2 — use bit selects)
    wire [5:0] hann_row_addr = cnt[11:6];   // cnt / 64
    wire [5:0] hann_col_addr = cnt[5:0];    // cnt % 64
    wire [DATA_WIDTH-1:0] hann_val_r, hann_val_c;

    hann_rom #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_hann_r (
        .addr(hann_row_addr), .w_out(hann_val_r)
    );
    hann_rom #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_hann_c (
        .addr(hann_col_addr), .w_out(hann_val_c)
    );

    // 2D Hann: hann[row] * hann[col] in Q8.8
    wire signed [2*DATA_WIDTH-1:0] hann_prod = $signed({1'b0, hann_val_r}) *
                                               $signed({1'b0, hann_val_c});
    wire signed [DATA_WIDTH-1:0]   hann_2d   = hann_prod[FRAC+DATA_WIDTH-1:FRAC];

    // Hann-windowed template pixel (combinational from cnt)
    wire signed [2*DATA_WIDTH-1:0] tmpl_win_prod = tmpl_buf[cnt[11:0]]  * hann_2d;
    wire signed [DATA_WIDTH-1:0]   tmpl_win_v    = tmpl_win_prod[FRAC+DATA_WIDTH-1:FRAC];

    // Hann-windowed patch pixel (combinational from cnt)
    wire signed [2*DATA_WIDTH-1:0] patch_win_prod = patch_buf[cnt[11:0]] * hann_2d;
    wire signed [DATA_WIDTH-1:0]   patch_win_v    = patch_win_prod[FRAC+DATA_WIDTH-1:FRAC];

    // FFT2D — shared for template init and patch detection
    reg  [$clog2(TOTAL)-1:0]        fft_wr_addr;
    reg  signed [DATA_WIDTH-1:0]    fft_wr_re, fft_wr_im;
    reg                             fft_wr_en, fft_start;
    wire                            fft_done;
    wire signed [DATA_WIDTH-1:0]    fft_rd_re, fft_rd_im;

    // rd_addr is cnt[11:0] — combinational so cmul/save are zero-latency
    fft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC),
               .SCALE_EN_ROW(1), .SCALE_EN_COL(0)) u_fft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(fft_wr_addr), .wr_data_re(fft_wr_re),
        .wr_data_im(fft_wr_im), .wr_en(fft_wr_en),
        .start(fft_start),
        .rd_addr(cnt[11:0]), .rd_data_re(fft_rd_re), .rd_data_im(fft_rd_im),
        .done(fft_done)
    );

    // Conjugate multiplier: FFT(patch) * conj(FFT(template))
    // a = FFT(patch)     (not conjugated)
    // b = FFT(template)  (conjugated internally by cconj_mul)
    wire signed [DATA_WIDTH-1:0] cmul_out_re, cmul_out_im;

    cconj_mul #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cconj (
        .a_re(fft_rd_re),              // FFT(patch)[cnt]
        .a_im(fft_rd_im),
        .b_re(alpha_re[cnt[11:0]]),    // FFT(template)[cnt] — conjugated by module
        .b_im(alpha_im[cnt[11:0]]),
        .out_re(cmul_out_re), .out_im(cmul_out_im)
    );

    // Element multiply output buffer
    reg signed [DATA_WIDTH-1:0] mul_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_im [0:TOTAL-1];

    // IFFT2D
    reg  [$clog2(TOTAL)-1:0]        ifft_wr_addr;
    reg  signed [DATA_WIDTH-1:0]    ifft_wr_re, ifft_wr_im;
    reg                             ifft_wr_en, ifft_start;
    wire                            ifft_done;
    wire signed [DATA_WIDTH-1:0]    ifft_rd_re, ifft_rd_im;

    // ifft rd_addr is also cnt[11:0] — combinational read during PEAK_RUN
    ifft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_ifft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(ifft_wr_addr), .wr_data_re(ifft_wr_re),
        .wr_data_im(ifft_wr_im), .wr_en(ifft_wr_en),
        .start(ifft_start),
        .rd_addr(cnt[11:0]), .rd_data_re(ifft_rd_re), .rd_data_im(ifft_rd_im),
        .done(ifft_done)
    );

    // Peak finder
    reg  signed [DATA_WIDTH-1:0] resp_map [0:TOTAL-1];
    reg  pk_start;
    wire pk_done;
    wire [$clog2(N)-1:0] pk_row, pk_col;
    wire signed [DATA_WIDTH-1:0] pk_val;

    peak_finder #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_peak (
        .clk(clk), .rst_n(rst_n),
        .start(pk_start),
        .response(resp_map),
        .peak_row(pk_row), .peak_col(pk_col), .peak_val(pk_val),
        .done(pk_done)
    );

    // ── Main FSM ────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            cnt        <= 0;
            fft_wr_en  <= 0;
            fft_start  <= 0;
            ifft_wr_en <= 0;
            ifft_start <= 0;
            pk_start   <= 0;
            tmpl_ready <= 0;
            done       <= 0;
        end else begin
            // Pulse defaults
            fft_wr_en  <= 0;
            fft_start  <= 0;
            ifft_wr_en <= 0;
            ifft_start <= 0;
            pk_start   <= 0;
            done       <= 0;

            case (state)

                // ── Accept pixel writes; choose template-init or detection ──
                S_IDLE: begin
                    if (tmpl_wr_en)
                        tmpl_buf[tmpl_wr_addr] <= tmpl_wr_data;
                    if (patch_wr_en)
                        patch_buf[patch_addr]  <= patch_data;

                    if (tmpl_init) begin
                        tmpl_ready <= 0;
                        cnt        <= 0;
                        state      <= S_TMPL_FFT_LD;
                    end else if (start && tmpl_ready) begin
                        cnt   <= 0;
                        state <= S_PATCH_FFT_LD;
                    end
                end

                // ── Hann-window template and stream into FFT2D (4096 cycles) ─
                S_TMPL_FFT_LD: begin
                    fft_wr_addr <= cnt[11:0];
                    fft_wr_re   <= tmpl_win_v;   // Hann[row]*Hann[col]*tmpl_buf[cnt]
                    fft_wr_im   <= 0;
                    fft_wr_en   <= 1;
                    if (cnt == TOTAL - 1) begin
                        fft_start <= 1;
                        cnt       <= 0;
                        state     <= S_TMPL_FFT_RUN;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                S_TMPL_FFT_RUN: begin
                    if (fft_done) begin
                        cnt   <= 0;
                        state <= S_TMPL_SAVE;
                    end
                end

                // ── Save FFT(Hann*template) to alpha arrays (4096 cycles) ────
                // fft_rd_addr = cnt[11:0] is a wire — read is combinational
                S_TMPL_SAVE: begin
                    alpha_re[cnt[11:0]] <= fft_rd_re;
                    alpha_im[cnt[11:0]] <= fft_rd_im;
                    if (cnt == TOTAL - 1) begin
                        tmpl_ready <= 1;
                        state      <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // ── Hann-window patch and stream into FFT2D (4096 cycles) ────
                S_PATCH_FFT_LD: begin
                    fft_wr_addr <= cnt[11:0];
                    fft_wr_re   <= patch_win_v;  // Hann[row]*Hann[col]*patch_buf[cnt]
                    fft_wr_im   <= 0;
                    fft_wr_en   <= 1;
                    if (cnt == TOTAL - 1) begin
                        fft_start <= 1;
                        cnt       <= 0;
                        state     <= S_PATCH_FFT_RN;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                S_PATCH_FFT_RN: begin
                    if (fft_done) begin
                        cnt   <= 0;
                        state <= S_ELEM_MUL;
                    end
                end

                // ── Element-wise conj(FFT(template)) * FFT(patch) ────────────
                // fft2d stays in S_IDLE after done; buf_re/im readable via rd_addr wire
                S_ELEM_MUL: begin
                    mul_re[cnt[11:0]] <= cmul_out_re;
                    mul_im[cnt[11:0]] <= cmul_out_im;
                    if (cnt == TOTAL - 1) begin
                        cnt   <= 0;
                        state <= S_IFFT_LOAD;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // ── Feed correlation spectrum into IFFT2D (4096 cycles) ──────
                S_IFFT_LOAD: begin
                    ifft_wr_addr <= cnt[11:0];
                    ifft_wr_re   <= mul_re[cnt[11:0]];
                    ifft_wr_im   <= mul_im[cnt[11:0]];
                    ifft_wr_en   <= 1;
                    if (cnt == TOTAL - 1) begin
                        ifft_start <= 1;
                        cnt        <= 0;
                        state      <= S_IFFT_RUN;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                S_IFFT_RUN: begin
                    if (ifft_done) begin
                        cnt   <= 0;
                        state <= S_PEAK_RUN;
                    end
                end

                // ── Copy IFFT real output to response map; launch peak finder ─
                // ifft rd_addr = cnt[11:0] is combinational — no read latency.
                // Fill resp_map[0..TOTAL-1], then assert pk_start on the last cycle.
                S_PEAK_RUN: begin
                    if (cnt < TOTAL) begin
                        resp_map[cnt[11:0]] <= ifft_rd_re;
                        if (cnt == TOTAL - 1)
                            pk_start <= 1;
                        cnt <= cnt + 1;
                    end else begin
                        if (pk_done) begin
                            peak_row  <= pk_row;
                            peak_col  <= pk_col;
                            ncc_score <= pk_val;
                            state     <= S_DONE;
                        end
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
