`timescale 1ns/1ps
// kcf_top.sv
// KCF tracker for 64×64 patches using a linear (Wiener) kernel.
//
// Two operating modes triggered by control pulses:
//
//   detect_start — Detection:
//     Hann-window patch → FFT2D → conj(alpha) * X_hat → IFFT2D → peak finder.
//     Saves X_hat internally for the subsequent update phase.
//
//   update_start — Filter update (runs after detect_start):
//     Loads Gaussian label Y from ROM → FFT2D → Y_hat.
//     Computes alpha[k] = Y_hat[k] / (|X_hat[k]|^2 + lambda)  per bin
//     using linear (Wiener) kernel — no gauss_kernel.sv needed.
//     Stores new alpha back to on-chip BRAM.
//
// After reset, the module automatically pre-computes Y_hat from gauss_label_rom
// before asserting init_done.  Subsequent updates reuse this fixed Y_hat.
//
// External alpha initialisation (optional):
//   Write alpha BRAM via alpha_wr_en / alpha_wr_addr / alpha_wr_re / alpha_wr_im
//   while in S_IDLE (e.g., for NCC → KCF handover seed).

module kcf_top #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                           clk,
    input  wire                           rst_n,

    // Patch pixel write interface
    input  wire [$clog2(N*N)-1:0]         patch_addr,
    input  wire signed [DATA_WIDTH-1:0]   patch_data,
    input  wire                           patch_wr_en,

    // Control
    input  wire                           detect_start,
    input  wire                           update_start,

    // Alpha BRAM external write (initialisation)
    input  wire [$clog2(N*N)-1:0]         alpha_wr_addr,
    input  wire signed [DATA_WIDTH-1:0]   alpha_wr_re,
    input  wire signed [DATA_WIDTH-1:0]   alpha_wr_im,
    input  wire                           alpha_wr_en,

    // Regularisation (Q8.8, e.g. 0x0003 ≈ 0.01)
    input  wire signed [DATA_WIDTH-1:0]   lambda,

    // Outputs
    output reg  [$clog2(N)-1:0]           peak_row,
    output reg  [$clog2(N)-1:0]           peak_col,
    output reg  signed [DATA_WIDTH-1:0]   peak_val,
    output reg                            detect_done,
    output reg                            update_done,
    output reg                            init_done    // pulsed once after Y_hat init
);

    localparam TOTAL = N * N;   // 4096

    // ── FSM states ──────────────────────────────────────────────────────────
    localparam S_IDLE      = 4'd0;
    localparam S_INIT_LD   = 4'd1;   // load gauss_label to FFT
    localparam S_INIT_RUN  = 4'd2;   // wait FFT(Y) done
    localparam S_INIT_SAV  = 4'd3;   // save Y_hat; pulse init_done
    localparam S_D_FFT_LD  = 4'd4;   // Hann*patch → FFT
    localparam S_D_FFT_RN  = 4'd5;   // wait FFT done
    localparam S_D_XHAT_SV = 4'd6;   // save X_hat for update
    localparam S_D_MUL     = 4'd7;   // conj(alpha) * X_hat → mul_buf
    localparam S_D_IFFT_LD = 4'd8;   // mul_buf → IFFT
    localparam S_D_IFFT_RN = 4'd9;   // wait IFFT done
    localparam S_D_PEAK    = 4'd10;  // fill resp_map, run peak finder
    localparam S_D_DONE    = 4'd11;  // pulse detect_done
    localparam S_U_ALPHA   = 4'd12;  // compute and store new alpha
    localparam S_U_DONE    = 4'd13;  // pulse update_done

    reg [3:0]  state;
    reg [12:0] cnt;   // 0..4097

    // ── Input patch buffer ──────────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] patch_buf [0:TOTAL-1];

    // ── Alpha BRAM (filter coefficients, complex) ───────────────────────────
    reg signed [DATA_WIDTH-1:0] alpha_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_im [0:TOTAL-1];

    // ── Saved X_hat = FFT(Hann*patch) — reused by update phase ─────────────
    reg signed [DATA_WIDTH-1:0] x_hat_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] x_hat_im [0:TOTAL-1];

    // ── Y_hat = FFT(Gauss_label) — computed once at init ───────────────────
    reg signed [DATA_WIDTH-1:0] y_hat_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] y_hat_im [0:TOTAL-1];

    // ── Hann ROM (2 instances, driven by cnt row/col addresses) ─────────────
    wire [5:0] hann_row_addr = cnt[11:6];   // cnt / 64
    wire [5:0] hann_col_addr = cnt[5:0];    // cnt % 64
    wire [DATA_WIDTH-1:0] hann_val_r, hann_val_c;

    hann_rom #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_hann_r (
        .addr(hann_row_addr), .w_out(hann_val_r)
    );
    hann_rom #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_hann_c (
        .addr(hann_col_addr), .w_out(hann_val_c)
    );

    wire signed [2*DATA_WIDTH-1:0] hann_prod = $signed({1'b0, hann_val_r}) *
                                               $signed({1'b0, hann_val_c});
    wire signed [DATA_WIDTH-1:0]   hann_2d   = hann_prod[FRAC+DATA_WIDTH-1:FRAC];

    wire signed [2*DATA_WIDTH-1:0] patch_win_p = patch_buf[cnt[11:0]] * hann_2d;
    wire signed [DATA_WIDTH-1:0]   patch_win_v = patch_win_p[FRAC+DATA_WIDTH-1:FRAC];

    // ── Gaussian label ROM ──────────────────────────────────────────────────
    wire [DATA_WIDTH-1:0] gauss_y;

    gauss_label_rom #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_gauss (
        .addr(cnt[11:0]), .y_out(gauss_y)
    );

    // ── FFT2D ───────────────────────────────────────────────────────────────
    reg  [$clog2(TOTAL)-1:0]        fft_wr_addr;
    reg  signed [DATA_WIDTH-1:0]    fft_wr_re, fft_wr_im;
    reg                             fft_wr_en, fft_start;
    wire                            fft_done;
    wire signed [DATA_WIDTH-1:0]    fft_rd_re, fft_rd_im;

    fft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC),
               .SCALE_EN_ROW(1), .SCALE_EN_COL(0)) u_fft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(fft_wr_addr), .wr_data_re(fft_wr_re),
        .wr_data_im(fft_wr_im), .wr_en(fft_wr_en),
        .start(fft_start),
        .rd_addr(cnt[11:0]), .rd_data_re(fft_rd_re), .rd_data_im(fft_rd_im),
        .done(fft_done)
    );

    // ── Conjugate multiply: conj(alpha) * X_hat ─────────────────────────────
    wire signed [DATA_WIDTH-1:0] cmul_out_re, cmul_out_im;

    cconj_mul #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cconj (
        .a_re(fft_rd_re),            // X_hat[cnt]
        .a_im(fft_rd_im),
        .b_re(alpha_re[cnt[11:0]]),  // alpha[cnt] — conjugated by module
        .b_im(alpha_im[cnt[11:0]]),
        .out_re(cmul_out_re), .out_im(cmul_out_im)
    );

    // ── Element multiply buffer ─────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] mul_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_im [0:TOTAL-1];

    // ── IFFT2D ──────────────────────────────────────────────────────────────
    reg  [$clog2(TOTAL)-1:0]        ifft_wr_addr;
    reg  signed [DATA_WIDTH-1:0]    ifft_wr_re, ifft_wr_im;
    reg                             ifft_wr_en, ifft_start;
    wire                            ifft_done;
    wire signed [DATA_WIDTH-1:0]    ifft_rd_re, ifft_rd_im;

    ifft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_ifft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(ifft_wr_addr), .wr_data_re(ifft_wr_re),
        .wr_data_im(ifft_wr_im), .wr_en(ifft_wr_en),
        .start(ifft_start),
        .rd_addr(cnt[11:0]), .rd_data_re(ifft_rd_re), .rd_data_im(ifft_rd_im),
        .done(ifft_done)
    );

    // ── Peak finder ─────────────────────────────────────────────────────────
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

    // ── Linear kernel: |X_hat[k]|^2 = x_re^2 + x_im^2 (Q8.8 normalised) ───
    // Inputs are x_hat_re/im[cnt]; sum of squares with saturation kept in Q8.8
    wire signed [DATA_WIDTH-1:0] xk_re = x_hat_re[cnt[11:0]];
    wire signed [DATA_WIDTH-1:0] xk_im = x_hat_im[cnt[11:0]];
    wire signed [2*DATA_WIDTH-1:0] re_sq   = xk_re * xk_re;
    wire signed [2*DATA_WIDTH-1:0] im_sq   = xk_im * xk_im;
    wire signed [DATA_WIDTH-1:0]   mag_sq  = re_sq[FRAC+DATA_WIDTH-1:FRAC] +
                                             im_sq[FRAC+DATA_WIDTH-1:FRAC];

    // ── cdiv: new_alpha = Y_hat / (|X_hat|^2 + lambda) ─────────────────────
    wire signed [DATA_WIDTH-1:0] cdiv_re, cdiv_im;
    wire                         cdiv_dbz;

    cdiv #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cdiv (
        .num_re  (y_hat_re[cnt[11:0]]),
        .num_im  (y_hat_im[cnt[11:0]]),
        .denom_re(mag_sq),
        .lambda  (lambda),
        .out_re  (cdiv_re),
        .out_im  (cdiv_im),
        .div_by_zero(cdiv_dbz)
    );

    // ── Main FSM ─────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_INIT_LD;   // auto-start Y_hat initialisation
            cnt         <= 0;
            fft_wr_en   <= 0;
            fft_start   <= 0;
            ifft_wr_en  <= 0;
            ifft_start  <= 0;
            pk_start    <= 0;
            detect_done <= 0;
            update_done <= 0;
            init_done   <= 0;
        end else begin
            fft_wr_en   <= 0;
            fft_start   <= 0;
            ifft_wr_en  <= 0;
            ifft_start  <= 0;
            pk_start    <= 0;
            detect_done <= 0;
            update_done <= 0;
            init_done   <= 0;

            case (state)

                // ── Idle: accept patch and alpha writes ───────────────────
                S_IDLE: begin
                    if (patch_wr_en)
                        patch_buf[patch_addr] <= patch_data;
                    if (alpha_wr_en) begin
                        alpha_re[alpha_wr_addr] <= alpha_wr_re;
                        alpha_im[alpha_wr_addr] <= alpha_wr_im;
                    end
                    if (detect_start) begin
                        cnt   <= 0;
                        state <= S_D_FFT_LD;
                    end else if (update_start) begin
                        cnt   <= 0;
                        state <= S_U_ALPHA;
                    end
                end

                // ──────────────── Y_hat initialisation (one-time) ─────────
                // Load Gaussian label ROM → FFT (gauss_y is combinational from cnt)
                S_INIT_LD: begin
                    fft_wr_addr <= cnt[11:0];
                    fft_wr_re   <= $signed({1'b0, gauss_y[DATA_WIDTH-1:0]});
                    fft_wr_im   <= 0;
                    fft_wr_en   <= 1;
                    if (cnt == TOTAL - 1) begin
                        fft_start <= 1;
                        cnt       <= 0;
                        state     <= S_INIT_RUN;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                S_INIT_RUN: begin
                    if (fft_done) begin cnt <= 0; state <= S_INIT_SAV; end
                end

                // Save Y_hat; fft rd_addr = cnt[11:0] (combinational)
                S_INIT_SAV: begin
                    y_hat_re[cnt[11:0]] <= fft_rd_re;
                    y_hat_im[cnt[11:0]] <= fft_rd_im;
                    if (cnt == TOTAL - 1) begin
                        init_done <= 1;
                        state     <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // ──────────────── Detection phase ─────────────────────────
                // Hann-window patch and stream to FFT
                S_D_FFT_LD: begin
                    fft_wr_addr <= cnt[11:0];
                    fft_wr_re   <= patch_win_v;
                    fft_wr_im   <= 0;
                    fft_wr_en   <= 1;
                    if (cnt == TOTAL - 1) begin
                        fft_start <= 1;
                        cnt       <= 0;
                        state     <= S_D_FFT_RN;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                S_D_FFT_RN: begin
                    if (fft_done) begin cnt <= 0; state <= S_D_XHAT_SV; end
                end

                // Save X_hat for the update phase
                S_D_XHAT_SV: begin
                    x_hat_re[cnt[11:0]] <= fft_rd_re;
                    x_hat_im[cnt[11:0]] <= fft_rd_im;
                    if (cnt == TOTAL - 1) begin
                        cnt   <= 0;
                        state <= S_D_MUL;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // Element-wise conj(alpha) * X_hat → mul_buf
                S_D_MUL: begin
                    mul_re[cnt[11:0]] <= cmul_out_re;
                    mul_im[cnt[11:0]] <= cmul_out_im;
                    if (cnt == TOTAL - 1) begin
                        cnt   <= 0;
                        state <= S_D_IFFT_LD;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // Feed mul_buf to IFFT
                S_D_IFFT_LD: begin
                    ifft_wr_addr <= cnt[11:0];
                    ifft_wr_re   <= mul_re[cnt[11:0]];
                    ifft_wr_im   <= mul_im[cnt[11:0]];
                    ifft_wr_en   <= 1;
                    if (cnt == TOTAL - 1) begin
                        ifft_start <= 1;
                        cnt        <= 0;
                        state      <= S_D_IFFT_RN;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                S_D_IFFT_RN: begin
                    if (ifft_done) begin cnt <= 0; state <= S_D_PEAK; end
                end

                // Fill response map from IFFT (combinational rd), launch peak finder
                S_D_PEAK: begin
                    if (cnt < TOTAL) begin
                        resp_map[cnt[11:0]] <= ifft_rd_re;
                        if (cnt == TOTAL - 1)
                            pk_start <= 1;
                        cnt <= cnt + 1;
                    end else begin
                        if (pk_done) begin
                            peak_row <= pk_row;
                            peak_col <= pk_col;
                            peak_val <= pk_val;
                            state    <= S_D_DONE;
                        end
                    end
                end

                S_D_DONE: begin
                    detect_done <= 1;
                    state       <= S_IDLE;
                end

                // ──────────────── Update phase ─────────────────────────────
                // Compute alpha[k] = Y_hat[k] / (|X_hat[k]|^2 + lambda) and store.
                // cdiv inputs (y_hat, x_hat, lambda) are all combinational from cnt[11:0].
                S_U_ALPHA: begin
                    alpha_re[cnt[11:0]] <= cdiv_re;
                    alpha_im[cnt[11:0]] <= cdiv_im;
                    if (cnt == TOTAL - 1) begin
                        state <= S_U_DONE;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                S_U_DONE: begin
                    update_done <= 1;
                    state       <= S_IDLE;
                end

            endcase
        end
    end

endmodule
