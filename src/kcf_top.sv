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
//     Computes alpha[k] = Y_hat[k] / (|X_hat[k]|^2 + lambda) per bin using a
//     sequential divider (~20 cycles/element), linear (Wiener) kernel.
//
// After reset, the module automatically pre-computes Y_hat = FFT(gauss_label)
// before asserting init_done.  Subsequent updates reuse this fixed Y_hat.
//
// External alpha initialisation (optional):
//   Write alpha BRAM via alpha_wr_en / alpha_wr_addr / alpha_wr_re / alpha_wr_im
//   while in S_IDLE (e.g., for NCC → KCF handover seed).
//
// SYNTHESIZABLE VERSION — all large buffers (patch, alpha, x_hat, y_hat, mul,
// resp_map) are BRAMs with one sync write + one sync read port.  Streaming
// states use a cnt/cnt_d address pipeline (address at t, data at t+1).  The
// combinational divider (cdiv) is replaced by seq_div with start/done
// handshake; the gauss_label ROM has a registered (1-cycle) read.

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

    localparam TOTAL  = N * N;            // 4096
    localparam ADDR_W = $clog2(TOTAL);    // 12
    localparam LOG2N  = $clog2(N);        // 6

    // ── FSM states (16 — exactly fills 4 bits) ─────────────────────────────
    localparam S_IDLE      = 4'd0;
    localparam S_INIT_LD   = 4'd1;   // stream gauss_label ROM → FFT
    localparam S_INIT_RUN  = 4'd2;   // wait FFT(Y) done
    localparam S_INIT_SAV  = 4'd3;   // save Y_hat; pulse init_done
    localparam S_D_FFT_LD  = 4'd4;   // Hann·patch → FFT
    localparam S_D_FFT_RN  = 4'd5;   // wait FFT done
    localparam S_D_XHAT_SV = 4'd6;   // save X_hat for update
    localparam S_D_MUL     = 4'd7;   // conj(alpha) · X_hat → mul_buf
    localparam S_D_IFFT_LD = 4'd8;   // mul_buf → IFFT
    localparam S_D_IFFT_RN = 4'd9;   // wait IFFT done
    localparam S_D_RESP    = 4'd10;  // fill resp_map from IFFT
    localparam S_D_PKWAIT  = 4'd11;  // wait for peak-finder scan
    localparam S_D_DONE    = 4'd12;  // pulse detect_done
    localparam S_U_RD      = 4'd13;  // present x_hat/y_hat read address
    localparam S_U_DIV     = 4'd14;  // run seq_div, write alpha on done
    localparam S_U_DONE    = 4'd15;  // pulse update_done

    reg [3:0]         state;
    reg [ADDR_W-1:0]  cnt;      // stream address-issue counter / element index
    reg [ADDR_W-1:0]  cnt_d;    // element the arriving read data belongs to
    reg               cnt_v;    // read data this cycle is valid

    // Early declarations (used inside BRAM blocks below)
    wire signed [DATA_WIDTH-1:0] fft_rd_re, fft_rd_im;
    wire signed [DATA_WIDTH-1:0] ifft_rd_re, ifft_rd_im;
    wire signed [DATA_WIDTH-1:0] cmul_out_re, cmul_out_im;
    wire signed [DATA_WIDTH-1:0] div_out_re, div_out_im;
    wire                         div_done, div_busy, div_dbz;
    wire [ADDR_W-1:0]            pf_rd_addr;

    // ════════════════════════════════════════════════════════════════════
    //  BRAM buffers — dedicated always blocks for clean inference
    // ════════════════════════════════════════════════════════════════════

    // ── Input patch buffer ──────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] patch_buf [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] patch_rd;
    wire patch_we = (state == S_IDLE) && patch_wr_en;
    always @(posedge clk) begin
        if (patch_we) patch_buf[patch_addr] <= patch_data;
        patch_rd <= patch_buf[cnt];
    end

    // ── Alpha BRAM (filter coefficients, complex) ───────────────────────
    // Write sources: external seed (S_IDLE) or divider result (S_U_DIV).
    reg signed [DATA_WIDTH-1:0] alpha_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_im [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_rd_re, alpha_rd_im;

    reg                          alpha_we;
    reg  [ADDR_W-1:0]            alpha_waddr;
    reg  signed [DATA_WIDTH-1:0] alpha_wre, alpha_wim;
    always @(*) begin
        if (state == S_U_DIV && div_done) begin
            alpha_we    = 1'b1;
            alpha_waddr = cnt;
            alpha_wre   = div_out_re;
            alpha_wim   = div_out_im;
        end else begin
            alpha_we    = (state == S_IDLE) && alpha_wr_en;
            alpha_waddr = alpha_wr_addr;
            alpha_wre   = alpha_wr_re;
            alpha_wim   = alpha_wr_im;
        end
    end
    always @(posedge clk) begin
        if (alpha_we) begin
            alpha_re[alpha_waddr] <= alpha_wre;
            alpha_im[alpha_waddr] <= alpha_wim;
        end
        alpha_rd_re <= alpha_re[cnt];
        alpha_rd_im <= alpha_im[cnt];
    end

    // ── Saved X_hat = FFT(Hann·patch) — reused by update phase ─────────
    reg signed [DATA_WIDTH-1:0] x_hat_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] x_hat_im [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] x_rd_re, x_rd_im;
    wire xhat_we = (state == S_D_XHAT_SV) && cnt_v;
    always @(posedge clk) begin
        if (xhat_we) begin
            x_hat_re[cnt_d] <= fft_rd_re;
            x_hat_im[cnt_d] <= fft_rd_im;
        end
        x_rd_re <= x_hat_re[cnt];
        x_rd_im <= x_hat_im[cnt];
    end

    // ── Y_hat = FFT(gauss_label) — computed once at init ───────────────
    reg signed [DATA_WIDTH-1:0] y_hat_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] y_hat_im [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] y_rd_re, y_rd_im;
    wire yhat_we = (state == S_INIT_SAV) && cnt_v;
    always @(posedge clk) begin
        if (yhat_we) begin
            y_hat_re[cnt_d] <= fft_rd_re;
            y_hat_im[cnt_d] <= fft_rd_im;
        end
        y_rd_re <= y_hat_re[cnt];
        y_rd_im <= y_hat_im[cnt];
    end

    // ── Element-multiply buffer ─────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] mul_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_im [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_rd_re, mul_rd_im;
    wire mul_we = (state == S_D_MUL) && cnt_v;
    always @(posedge clk) begin
        if (mul_we) begin
            mul_re[cnt_d] <= cmul_out_re;
            mul_im[cnt_d] <= cmul_out_im;
        end
        mul_rd_re <= mul_re[cnt];
        mul_rd_im <= mul_im[cnt];
    end

    // ── Response map (written from IFFT, scanned by peak_finder) ────────
    reg signed [DATA_WIDTH-1:0] resp_map [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] resp_rd;
    wire resp_we = (state == S_D_RESP) && cnt_v;
    always @(posedge clk) begin
        if (resp_we) resp_map[cnt_d] <= ifft_rd_re;
        resp_rd <= resp_map[pf_rd_addr];
    end

    // ════════════════════════════════════════════════════════════════════
    //  Hann window — 2D coefficient addressed by cnt_d (data phase)
    // ════════════════════════════════════════════════════════════════════
    wire [LOG2N-1:0] hann_row_addr = cnt_d[ADDR_W-1:LOG2N];
    wire [LOG2N-1:0] hann_col_addr = cnt_d[LOG2N-1:0];
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

    // Windowed patch pixel — registered BRAM output, element cnt_d
    wire signed [2*DATA_WIDTH-1:0] patch_win_p = patch_rd * hann_2d;
    wire signed [DATA_WIDTH-1:0]   patch_win_v = patch_win_p[FRAC+DATA_WIDTH-1:FRAC];

    // ── Gaussian label ROM — SYNCHRONOUS read (BRAM), data for cnt_d ────
    wire [DATA_WIDTH-1:0] gauss_y;

    gauss_label_rom #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_gauss (
        .clk(clk), .addr(cnt), .y_out(gauss_y)
    );

    // ════════════════════════════════════════════════════════════════════
    //  FFT2D — rd_data has 1-cycle latency (registered inside fft2d_64)
    // ════════════════════════════════════════════════════════════════════
    reg  [ADDR_W-1:0]            fft_wr_addr;
    reg  signed [DATA_WIDTH-1:0] fft_wr_re, fft_wr_im;
    reg                          fft_wr_en, fft_start;
    wire                         fft_done;

    fft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC),
               .SCALE_EN_ROW(1), .SCALE_EN_COL(0)) u_fft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(fft_wr_addr), .wr_data_re(fft_wr_re),
        .wr_data_im(fft_wr_im), .wr_en(fft_wr_en),
        .start(fft_start),
        .rd_addr(cnt), .rd_data_re(fft_rd_re), .rd_data_im(fft_rd_im),
        .done(fft_done)
    );

    // ── Conjugate multiply: conj(alpha) · X_hat — operands at cnt_d ─────
    cconj_mul #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cconj (
        .a_re(fft_rd_re),        // X_hat[cnt_d]
        .a_im(fft_rd_im),
        .b_re(alpha_rd_re),      // alpha[cnt_d] — conjugated by module
        .b_im(alpha_rd_im),
        .out_re(cmul_out_re), .out_im(cmul_out_im)
    );

    // ════════════════════════════════════════════════════════════════════
    //  IFFT2D — rd_data has 1-cycle latency
    // ════════════════════════════════════════════════════════════════════
    reg  [ADDR_W-1:0]            ifft_wr_addr;
    reg  signed [DATA_WIDTH-1:0] ifft_wr_re, ifft_wr_im;
    reg                          ifft_wr_en, ifft_start;
    wire                         ifft_done;

    ifft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_ifft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(ifft_wr_addr), .wr_data_re(ifft_wr_re),
        .wr_data_im(ifft_wr_im), .wr_en(ifft_wr_en),
        .start(ifft_start),
        .rd_addr(cnt), .rd_data_re(ifft_rd_re), .rd_data_im(ifft_rd_im),
        .done(ifft_done)
    );

    // ════════════════════════════════════════════════════════════════════
    //  Peak finder — read master on resp_map BRAM
    // ════════════════════════════════════════════════════════════════════
    reg  pk_start;
    wire pk_done;
    wire [LOG2N-1:0] pk_row, pk_col;
    wire signed [DATA_WIDTH-1:0] pk_val;

    peak_finder #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_peak (
        .clk(clk), .rst_n(rst_n),
        .start(pk_start),
        .rd_addr(pf_rd_addr), .rd_data(resp_rd),
        .peak_row(pk_row), .peak_col(pk_col), .peak_val(pk_val),
        .done(pk_done)
    );

    // ════════════════════════════════════════════════════════════════════
    //  Update path: |X_hat|² and the sequential divider
    //  x_rd / y_rd are the registered BRAM outputs for element `cnt`
    //  (address presented in S_U_RD, data stable from the first S_U_DIV cycle)
    // ════════════════════════════════════════════════════════════════════
    wire signed [2*DATA_WIDTH-1:0] re_sq  = x_rd_re * x_rd_re;
    wire signed [2*DATA_WIDTH-1:0] im_sq  = x_rd_im * x_rd_im;
    wire signed [DATA_WIDTH-1:0]   mag_sq = re_sq[FRAC+DATA_WIDTH-1:FRAC] +
                                            im_sq[FRAC+DATA_WIDTH-1:FRAC];

    reg div_start;

    seq_div #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_div (
        .clk(clk), .rst_n(rst_n),
        .start(div_start),
        .num_re  (y_rd_re),
        .num_im  (y_rd_im),
        .denom_re(mag_sq),
        .lambda  (lambda),
        .out_re  (div_out_re),
        .out_im  (div_out_im),
        .div_by_zero(div_dbz),
        .busy(div_busy),
        .done(div_done)
    );

    // ════════════════════════════════════════════════════════════════════
    //  Main FSM
    // ════════════════════════════════════════════════════════════════════
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_INIT_LD;   // auto-start Y_hat initialisation
            cnt         <= {ADDR_W{1'b0}};
            cnt_d       <= {ADDR_W{1'b0}};
            cnt_v       <= 1'b0;
            fft_wr_en   <= 1'b0;
            fft_start   <= 1'b0;
            fft_wr_addr <= {ADDR_W{1'b0}};
            fft_wr_re   <= {DATA_WIDTH{1'b0}};
            fft_wr_im   <= {DATA_WIDTH{1'b0}};
            ifft_wr_en  <= 1'b0;
            ifft_start  <= 1'b0;
            ifft_wr_addr<= {ADDR_W{1'b0}};
            ifft_wr_re  <= {DATA_WIDTH{1'b0}};
            ifft_wr_im  <= {DATA_WIDTH{1'b0}};
            pk_start    <= 1'b0;
            div_start   <= 1'b0;
            detect_done <= 1'b0;
            update_done <= 1'b0;
            init_done   <= 1'b0;
            peak_row    <= {LOG2N{1'b0}};
            peak_col    <= {LOG2N{1'b0}};
            peak_val    <= {DATA_WIDTH{1'b0}};
        end else begin
            fft_wr_en   <= 1'b0;
            fft_start   <= 1'b0;
            ifft_wr_en  <= 1'b0;
            ifft_start  <= 1'b0;
            pk_start    <= 1'b0;
            div_start   <= 1'b0;
            detect_done <= 1'b0;
            update_done <= 1'b0;
            init_done   <= 1'b0;

            case (state)

                // ── Idle: patch/alpha writes handled by BRAM blocks ───────
                S_IDLE: begin
                    cnt_v <= 1'b0;
                    if (detect_start) begin
                        cnt   <= {ADDR_W{1'b0}};
                        state <= S_D_FFT_LD;
                    end else if (update_start) begin
                        cnt   <= {ADDR_W{1'b0}};
                        state <= S_U_RD;
                    end
                end

                // ──────────────── Y_hat initialisation (one-time) ─────────
                // Stream gauss_label ROM (sync, data for cnt_d) into FFT
                S_INIT_LD: begin
                    if (cnt_v) begin
                        fft_wr_addr <= cnt_d;
                        fft_wr_re   <= $signed(gauss_y);   // label values ≤ 0x0100, sign bit 0
                        fft_wr_im   <= {DATA_WIDTH{1'b0}};
                        fft_wr_en   <= 1'b1;
                    end
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        fft_start <= 1'b1;
                        cnt       <= {ADDR_W{1'b0}};
                        cnt_v     <= 1'b0;
                        state     <= S_INIT_RUN;
                    end
                end

                S_INIT_RUN: begin
                    if (fft_done) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_INIT_SAV;
                    end
                end

                // Save Y_hat (write handled by y_hat BRAM block, yhat_we)
                S_INIT_SAV: begin
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        init_done <= 1'b1;
                        cnt_v     <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                // ──────────────── Detection phase ─────────────────────────
                S_D_FFT_LD: begin
                    if (cnt_v) begin
                        fft_wr_addr <= cnt_d;
                        fft_wr_re   <= patch_win_v;
                        fft_wr_im   <= {DATA_WIDTH{1'b0}};
                        fft_wr_en   <= 1'b1;
                    end
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        fft_start <= 1'b1;
                        cnt       <= {ADDR_W{1'b0}};
                        cnt_v     <= 1'b0;
                        state     <= S_D_FFT_RN;
                    end
                end

                S_D_FFT_RN: begin
                    if (fft_done) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_D_XHAT_SV;
                    end
                end

                // Save X_hat (write handled by x_hat BRAM block, xhat_we)
                S_D_XHAT_SV: begin
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_D_MUL;
                    end
                end

                // conj(alpha)·X_hat → mul BRAM (write handled by mul_we)
                S_D_MUL: begin
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_D_IFFT_LD;
                    end
                end

                // Feed mul BRAM into IFFT
                S_D_IFFT_LD: begin
                    if (cnt_v) begin
                        ifft_wr_addr <= cnt_d;
                        ifft_wr_re   <= mul_rd_re;
                        ifft_wr_im   <= mul_rd_im;
                        ifft_wr_en   <= 1'b1;
                    end
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        ifft_start <= 1'b1;
                        cnt        <= {ADDR_W{1'b0}};
                        cnt_v      <= 1'b0;
                        state      <= S_D_IFFT_RN;
                    end
                end

                S_D_IFFT_RN: begin
                    if (ifft_done) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_D_RESP;
                    end
                end

                // Fill resp_map from IFFT (write handled by resp_we)
                S_D_RESP: begin
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        pk_start <= 1'b1;
                        cnt_v    <= 1'b0;
                        state    <= S_D_PKWAIT;
                    end
                end

                S_D_PKWAIT: begin
                    if (pk_done) begin
                        peak_row <= pk_row;
                        peak_col <= pk_col;
                        peak_val <= pk_val;
                        state    <= S_D_DONE;
                    end
                end

                S_D_DONE: begin
                    detect_done <= 1'b1;
                    state       <= S_IDLE;
                end

                // ──────────────── Update phase ─────────────────────────────
                // Per element: present x_hat/y_hat address (S_U_RD, 1 cycle),
                // then start seq_div; on done the alpha write mux commits the
                // result and we advance to the next element.
                S_U_RD: begin
                    // Read address `cnt` is presented to x_hat/y_hat BRAMs;
                    // data is registered and stable from the next cycle.
                    div_start <= 1'b1;
                    state     <= S_U_DIV;
                end

                S_U_DIV: begin
                    // seq_div latches operands one cycle after div_start —
                    // exactly when x_rd/y_rd become valid.
                    if (div_done) begin
                        // alpha[cnt] written this cycle via the alpha write mux
                        if (cnt == TOTAL-1) begin
                            state <= S_U_DONE;
                        end else begin
                            cnt   <= cnt + 1'b1;
                            state <= S_U_RD;
                        end
                    end
                end

                S_U_DONE: begin
                    update_done <= 1'b1;
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
