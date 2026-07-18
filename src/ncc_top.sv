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
// SYNTHESIZABLE VERSION — every large buffer is a BRAM with one synchronous
// write port and one synchronous read port (registered output).  All streaming
// states use a cnt/cnt_d address pipeline: the address is presented at cycle t
// and the corresponding data is consumed at cycle t+1.  Each stream therefore
// takes N*N+1 cycles instead of N*N.
//
// BRAM buffers: tmpl_buf, patch_buf, alpha_re/im, mul_re/im, resp_map.

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

    localparam TOTAL  = N * N;            // 4096
    localparam ADDR_W = $clog2(TOTAL);    // 12
    localparam LOG2N  = $clog2(N);        // 6

    localparam S_IDLE         = 4'd0;
    localparam S_TMPL_FFT_LD  = 4'd1;
    localparam S_TMPL_FFT_RUN = 4'd2;
    localparam S_TMPL_SAVE    = 4'd3;
    localparam S_PATCH_FFT_LD = 4'd4;
    localparam S_PATCH_FFT_RN = 4'd5;
    localparam S_ELEM_MUL     = 4'd6;
    localparam S_IFFT_LOAD    = 4'd7;
    localparam S_IFFT_RUN     = 4'd8;
    localparam S_RESP_FILL    = 4'd9;
    localparam S_PEAK_WAIT    = 4'd10;
    localparam S_DONE         = 4'd11;

    reg [3:0]         state;
    reg [ADDR_W-1:0]  cnt;      // stream address-issue counter
    reg [ADDR_W-1:0]  cnt_d;    // element the arriving read data belongs to
    reg               cnt_v;    // read data this cycle is valid

    // ════════════════════════════════════════════════════════════════════
    //  BRAM buffers — each has a dedicated always block for clean inference
    // ════════════════════════════════════════════════════════════════════

    // ── Template pixel buffer ───────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] tmpl_buf [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] tmpl_rd;
    wire tmpl_we = (state == S_IDLE) && tmpl_wr_en;
    always @(posedge clk) begin
        if (tmpl_we) tmpl_buf[tmpl_wr_addr] <= tmpl_wr_data;
        tmpl_rd <= tmpl_buf[cnt];
    end

    // ── Search patch buffer ─────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] patch_buf [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] patch_rd;
    wire patch_we = (state == S_IDLE) && patch_wr_en;
    always @(posedge clk) begin
        if (patch_we) patch_buf[patch_addr] <= patch_data;
        patch_rd <= patch_buf[cnt];
    end

    // ── Frequency-domain template (un-conjugated FFT(Hann·template)) ────
    wire signed [DATA_WIDTH-1:0] fft_rd_re, fft_rd_im;   // fft2d output (decl early)
    reg signed [DATA_WIDTH-1:0] alpha_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_im [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_rd_re, alpha_rd_im;
    wire alpha_we = (state == S_TMPL_SAVE) && cnt_v;
    always @(posedge clk) begin
        if (alpha_we) begin
            alpha_re[cnt_d] <= fft_rd_re;
            alpha_im[cnt_d] <= fft_rd_im;
        end
        alpha_rd_re <= alpha_re[cnt];
        alpha_rd_im <= alpha_im[cnt];
    end

    // ── Element-multiply output buffer ──────────────────────────────────
    wire signed [DATA_WIDTH-1:0] cmul_out_re, cmul_out_im;   // decl early
    reg signed [DATA_WIDTH-1:0] mul_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_im [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_rd_re, mul_rd_im;
    wire mul_we = (state == S_ELEM_MUL) && cnt_v;
    always @(posedge clk) begin
        if (mul_we) begin
            mul_re[cnt_d] <= cmul_out_re;
            mul_im[cnt_d] <= cmul_out_im;
        end
        mul_rd_re <= mul_re[cnt];
        mul_rd_im <= mul_im[cnt];
    end

    // ── Response map (written from IFFT, scanned by peak_finder) ────────
    wire signed [DATA_WIDTH-1:0] ifft_rd_re, ifft_rd_im;    // decl early
    wire [ADDR_W-1:0]            pf_rd_addr;
    reg signed [DATA_WIDTH-1:0] resp_map [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] resp_rd;
    wire resp_we = (state == S_RESP_FILL) && cnt_v;
    always @(posedge clk) begin
        if (resp_we) resp_map[cnt_d] <= ifft_rd_re;
        resp_rd <= resp_map[pf_rd_addr];
    end

    // ════════════════════════════════════════════════════════════════════
    //  Hann window — 2D coefficient addressed by cnt_d (data phase)
    // ════════════════════════════════════════════════════════════════════
    wire [LOG2N-1:0] hann_row_addr = cnt_d[ADDR_W-1:LOG2N];   // cnt_d / 64
    wire [LOG2N-1:0] hann_col_addr = cnt_d[LOG2N-1:0];        // cnt_d % 64
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

    // Hann-windowed pixels — computed from the REGISTERED BRAM outputs,
    // so they correspond to element cnt_d
    wire signed [2*DATA_WIDTH-1:0] tmpl_win_prod  = tmpl_rd  * hann_2d;
    wire signed [DATA_WIDTH-1:0]   tmpl_win_v     = tmpl_win_prod[FRAC+DATA_WIDTH-1:FRAC];
    wire signed [2*DATA_WIDTH-1:0] patch_win_prod = patch_rd * hann_2d;
    wire signed [DATA_WIDTH-1:0]   patch_win_v    = patch_win_prod[FRAC+DATA_WIDTH-1:FRAC];

    // ════════════════════════════════════════════════════════════════════
    //  FFT2D — shared for template init and patch detection
    //  rd_data has 1-cycle latency (registered BRAM output inside fft2d_64)
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

    // Conjugate multiplier: FFT(patch) * conj(FFT(template))
    // Operands are both registered BRAM outputs for element cnt_d.
    cconj_mul #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cconj (
        .a_re(fft_rd_re),        // FFT(patch)[cnt_d]
        .a_im(fft_rd_im),
        .b_re(alpha_rd_re),      // FFT(template)[cnt_d] — conjugated by module
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
    //  Peak finder — read master on the resp_map BRAM
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
    //  Main FSM
    // ════════════════════════════════════════════════════════════════════
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            cnt        <= {ADDR_W{1'b0}};
            cnt_d      <= {ADDR_W{1'b0}};
            cnt_v      <= 1'b0;
            fft_wr_en  <= 1'b0;
            fft_start  <= 1'b0;
            fft_wr_addr<= {ADDR_W{1'b0}};
            fft_wr_re  <= {DATA_WIDTH{1'b0}};
            fft_wr_im  <= {DATA_WIDTH{1'b0}};
            ifft_wr_en <= 1'b0;
            ifft_start <= 1'b0;
            ifft_wr_addr <= {ADDR_W{1'b0}};
            ifft_wr_re <= {DATA_WIDTH{1'b0}};
            ifft_wr_im <= {DATA_WIDTH{1'b0}};
            pk_start   <= 1'b0;
            tmpl_ready <= 1'b0;
            done       <= 1'b0;
            peak_row   <= {LOG2N{1'b0}};
            peak_col   <= {LOG2N{1'b0}};
            ncc_score  <= {DATA_WIDTH{1'b0}};
        end else begin
            // Pulse defaults
            fft_wr_en  <= 1'b0;
            fft_start  <= 1'b0;
            ifft_wr_en <= 1'b0;
            ifft_start <= 1'b0;
            pk_start   <= 1'b0;
            done       <= 1'b0;

            case (state)

                // ── Pixel writes handled by BRAM blocks; choose operation ──
                S_IDLE: begin
                    cnt_v <= 1'b0;
                    if (tmpl_init) begin
                        tmpl_ready <= 1'b0;
                        cnt        <= {ADDR_W{1'b0}};
                        state      <= S_TMPL_FFT_LD;
                    end else if (start && tmpl_ready) begin
                        cnt   <= {ADDR_W{1'b0}};
                        state <= S_PATCH_FFT_LD;
                    end
                end

                // ── Hann-window template, stream into FFT2D (TOTAL+1 cyc) ──
                S_TMPL_FFT_LD: begin
                    if (cnt_v) begin
                        fft_wr_addr <= cnt_d;
                        fft_wr_re   <= tmpl_win_v;   // Hann2D · tmpl_buf[cnt_d]
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
                        state     <= S_TMPL_FFT_RUN;
                    end
                end

                S_TMPL_FFT_RUN: begin
                    if (fft_done) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_TMPL_SAVE;
                    end
                end

                // ── Save FFT(Hann·template) to alpha BRAMs (TOTAL+1 cyc) ───
                // fft2d rd_addr = cnt; data for cnt_d arrives registered.
                // alpha write handled by the alpha BRAM block (alpha_we).
                S_TMPL_SAVE: begin
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        tmpl_ready <= 1'b1;
                        cnt_v      <= 1'b0;
                        state      <= S_IDLE;
                    end
                end

                // ── Hann-window patch, stream into FFT2D (TOTAL+1 cyc) ─────
                S_PATCH_FFT_LD: begin
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
                        state     <= S_PATCH_FFT_RN;
                    end
                end

                S_PATCH_FFT_RN: begin
                    if (fft_done) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_ELEM_MUL;
                    end
                end

                // ── Element-wise conj(FFT(tmpl)) · FFT(patch) (TOTAL+1 cyc) ─
                // Reads fft2d[cnt] and alpha[cnt]; both registered outputs
                // align at cnt_d; cconj_mul is combinational; mul BRAM write
                // handled by mul_we.
                S_ELEM_MUL: begin
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_IFFT_LOAD;
                    end
                end

                // ── Feed correlation spectrum into IFFT2D (TOTAL+1 cyc) ────
                S_IFFT_LOAD: begin
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
                        state      <= S_IFFT_RUN;
                    end
                end

                S_IFFT_RUN: begin
                    if (ifft_done) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_RESP_FILL;
                    end
                end

                // ── Copy IFFT real output into resp_map BRAM (TOTAL+1 cyc) ─
                S_RESP_FILL: begin
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        pk_start <= 1'b1;
                        cnt_v    <= 1'b0;
                        state    <= S_PEAK_WAIT;
                    end
                end

                // ── Wait for the peak-finder scan ──────────────────────────
                S_PEAK_WAIT: begin
                    if (pk_done) begin
                        peak_row  <= pk_row;
                        peak_col  <= pk_col;
                        ncc_score <= pk_val;
                        state     <= S_DONE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
