`timescale 1ns/1ps
// kcf_detect_top.sv
// Scaled-down KCF detection-only top module for mid-project demo.
// 32×32 patch, linear kernel, frozen alpha from ROM, no AXI.
//
// Pipeline:
//   1. HANN_WIN  — apply 2D Hann window to input patch
//   2. FFT_LOAD  — load windowed patch into fft2d_32
//   3. FFT_RUN   — compute 2D FFT
//   4. ELEM_MUL  — conj(alpha_hat) ⊙ FFT(patch), one element/cycle
//   5. IFFT_LOAD — load product into ifft2d_32
//   6. IFFT_RUN  — compute 2D IFFT
//   7. RESP_FILL — copy IFFT output to response map
//   8. PEAK_WAIT — peak finder scans the response map
//
// SYNTHESIZABLE VERSION — all buffers are BRAMs (sync write + sync read);
// streaming states use a cnt/cnt_d address pipeline.  The frozen alpha
// filter loads from SPLIT .mem files (alpha_hat_re.mem / alpha_hat_im.mem,
// bare filenames for Vivado design-source resolution) — no procedural
// de-interleave loop in an initial block.

module kcf_detect_top #(
    parameter N          = 32,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           start,
    // Input patch: write one pixel per cycle before asserting start
    input  wire [$clog2(N*N)-1:0]         patch_addr,
    input  wire signed [DATA_WIDTH-1:0]   patch_data,
    input  wire                           patch_wr_en,
    // Confidence threshold (set before start; static during detection)
    input  wire signed [DATA_WIDTH-1:0]   conf_threshold,
    // Detection output
    output reg  [$clog2(N)-1:0]           peak_row,
    output reg  [$clog2(N)-1:0]           peak_col,
    output reg  signed [DATA_WIDTH-1:0]   peak_val,
    output reg                            target_found,
    output reg                            done
);

    localparam TOTAL  = N * N;            // 1024
    localparam ADDR_W = $clog2(TOTAL);    // 10
    localparam LOG2N  = $clog2(N);        // 5

    // ── FSM states ──────────────────────────────────────────────────────
    localparam S_IDLE      = 4'd0;
    localparam S_HANN_WIN  = 4'd1;
    localparam S_FFT_LOAD  = 4'd2;
    localparam S_FFT_RUN   = 4'd3;
    localparam S_ELEM_MUL  = 4'd4;
    localparam S_IFFT_LOAD = 4'd5;
    localparam S_IFFT_RUN  = 4'd6;
    localparam S_RESP_FILL = 4'd7;
    localparam S_PEAK_WAIT = 4'd8;
    localparam S_DONE      = 4'd9;

    reg [3:0]         state;
    reg [ADDR_W-1:0]  cnt;      // stream address-issue counter
    reg [ADDR_W-1:0]  cnt_d;    // element the arriving read data belongs to
    reg               cnt_v;    // read data this cycle is valid

    // Early declarations (used in BRAM blocks below)
    wire signed [DATA_WIDTH-1:0] fft_rd_re, fft_rd_im;
    wire signed [DATA_WIDTH-1:0] ifft_rd_re, ifft_rd_im;
    wire signed [DATA_WIDTH-1:0] cmul_out_re, cmul_out_im;
    wire [ADDR_W-1:0]            pf_rd_addr;

    // ════════════════════════════════════════════════════════════════════
    //  BRAM buffers
    // ════════════════════════════════════════════════════════════════════

    // ── Input patch buffer ──────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] patch_buf [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] patch_rd;
    wire patch_we = (state == S_IDLE) && patch_wr_en;
    always @(posedge clk) begin
        if (patch_we) patch_buf[patch_addr] <= patch_data;
        patch_rd <= patch_buf[cnt];
    end

    // ── Windowed patch buffer ───────────────────────────────────────────
    wire signed [DATA_WIDTH-1:0] win_val;   // decl early (window product below)
    reg signed [DATA_WIDTH-1:0] win_buf_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] win_rd;
    wire win_we = (state == S_HANN_WIN) && cnt_v;
    always @(posedge clk) begin
        if (win_we) win_buf_re[cnt_d] <= win_val;
        win_rd <= win_buf_re[cnt];
    end

    // ── Alpha hat ROMs (frozen filter, split re/im .mem files) ──────────
    reg signed [DATA_WIDTH-1:0] alpha_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_im [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_rd_re, alpha_rd_im;
    initial begin
        $readmemh("alpha_hat_re.mem", alpha_re);
        $readmemh("alpha_hat_im.mem", alpha_im);
    end
    always @(posedge clk) begin
        alpha_rd_re <= alpha_re[cnt];
        alpha_rd_im <= alpha_im[cnt];
    end

    // ── Element-multiply result buffer ──────────────────────────────────
    reg signed [DATA_WIDTH-1:0] mul_buf_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_buf_im [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_rd_re, mul_rd_im;
    wire mul_we = (state == S_ELEM_MUL) && cnt_v;
    always @(posedge clk) begin
        if (mul_we) begin
            mul_buf_re[cnt_d] <= cmul_out_re;
            mul_buf_im[cnt_d] <= cmul_out_im;
        end
        mul_rd_re <= mul_buf_re[cnt];
        mul_rd_im <= mul_buf_im[cnt];
    end

    // ── Response map (scanned by peak_finder) ───────────────────────────
    reg signed [DATA_WIDTH-1:0] resp_map [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] resp_rd;
    wire resp_we = (state == S_RESP_FILL) && cnt_v;
    always @(posedge clk) begin
        if (resp_we) resp_map[cnt_d] <= ifft_rd_re;
        resp_rd <= resp_map[pf_rd_addr];
    end

    // ════════════════════════════════════════════════════════════════════
    //  Hann window — addressed by cnt_d (data phase); bit-slice row/col
    // ════════════════════════════════════════════════════════════════════
    wire [LOG2N-1:0] hann_addr_r = cnt_d[ADDR_W-1:LOG2N];   // cnt_d / N
    wire [LOG2N-1:0] hann_addr_c = cnt_d[LOG2N-1:0];        // cnt_d % N
    wire [DATA_WIDTH-1:0] hann_val_r, hann_val_c;

    hann_rom_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_hann_r (
        .addr(hann_addr_r), .w_out(hann_val_r)
    );
    hann_rom_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_hann_c (
        .addr(hann_addr_c), .w_out(hann_val_c)
    );

    // Q8.8 × Q8.8 → Q16.16, keep [23:8] → Q8.8
    wire signed [2*DATA_WIDTH-1:0] hann_prod = $signed({1'b0, hann_val_r}) *
                                               $signed({1'b0, hann_val_c});
    wire signed [DATA_WIDTH-1:0]   hann_2d   = hann_prod[FRAC+DATA_WIDTH-1:FRAC];
    // Windowed pixel — patch_rd is the registered BRAM output for cnt_d
    wire signed [2*DATA_WIDTH-1:0] win_prod  = patch_rd * hann_2d;
    assign win_val = win_prod[FRAC+DATA_WIDTH-1:FRAC];

    // ════════════════════════════════════════════════════════════════════
    //  FFT2D — rd_data has 1-cycle latency (registered inside fft2d_32)
    // ════════════════════════════════════════════════════════════════════
    reg  [ADDR_W-1:0]            fft_wr_addr;
    reg  signed [DATA_WIDTH-1:0] fft_wr_data_re, fft_wr_data_im;
    reg                          fft_wr_en, fft_start;
    wire                         fft_done;

    fft2d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC),
               .SCALE_EN_ROW(1), .SCALE_EN_COL(0)) u_fft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(fft_wr_addr), .wr_data_re(fft_wr_data_re),
        .wr_data_im(fft_wr_data_im), .wr_en(fft_wr_en),
        .start(fft_start),
        .rd_addr(cnt), .rd_data_re(fft_rd_re), .rd_data_im(fft_rd_im),
        .done(fft_done)
    );

    // ── Conjugate multiplier — operands are registered outputs at cnt_d ─
    // conj(alpha) * X_hat: alpha goes to b (conjugated), X_hat goes to a
    cconj_mul #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cconj (
        .a_re(fft_rd_re),   .a_im(fft_rd_im),      // X_hat[cnt_d]
        .b_re(alpha_rd_re), .b_im(alpha_rd_im),    // alpha[cnt_d] (conjugated)
        .out_re(cmul_out_re), .out_im(cmul_out_im)
    );

    // ════════════════════════════════════════════════════════════════════
    //  IFFT2D — rd_data has 1-cycle latency
    // ════════════════════════════════════════════════════════════════════
    reg  [ADDR_W-1:0]            ifft_wr_addr;
    reg  signed [DATA_WIDTH-1:0] ifft_wr_data_re, ifft_wr_data_im;
    reg                          ifft_wr_en, ifft_start;
    wire                         ifft_done;

    ifft2d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_ifft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(ifft_wr_addr), .wr_data_re(ifft_wr_data_re),
        .wr_data_im(ifft_wr_data_im), .wr_en(ifft_wr_en),
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
    //  Main FSM
    // ════════════════════════════════════════════════════════════════════
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            cnt          <= {ADDR_W{1'b0}};
            cnt_d        <= {ADDR_W{1'b0}};
            cnt_v        <= 1'b0;
            fft_wr_en    <= 1'b0;
            fft_start    <= 1'b0;
            fft_wr_addr  <= {ADDR_W{1'b0}};
            fft_wr_data_re <= {DATA_WIDTH{1'b0}};
            fft_wr_data_im <= {DATA_WIDTH{1'b0}};
            ifft_wr_en   <= 1'b0;
            ifft_start   <= 1'b0;
            ifft_wr_addr <= {ADDR_W{1'b0}};
            ifft_wr_data_re <= {DATA_WIDTH{1'b0}};
            ifft_wr_data_im <= {DATA_WIDTH{1'b0}};
            pk_start     <= 1'b0;
            target_found <= 1'b0;
            done         <= 1'b0;
            peak_row     <= {LOG2N{1'b0}};
            peak_col     <= {LOG2N{1'b0}};
            peak_val     <= {DATA_WIDTH{1'b0}};
        end else begin
            // Defaults
            fft_wr_en  <= 1'b0;
            fft_start  <= 1'b0;
            ifft_wr_en <= 1'b0;
            ifft_start <= 1'b0;
            pk_start   <= 1'b0;
            done       <= 1'b0;

            case (state)

                // ── Patch writes handled by the patch BRAM block ─────────
                S_IDLE: begin
                    cnt_v <= 1'b0;
                    if (start) begin
                        cnt   <= {ADDR_W{1'b0}};
                        state <= S_HANN_WIN;
                    end
                end

                // ── Apply 2D Hann window (TOTAL+1 cycles) ────────────────
                // patch_rd arrives for cnt_d; win_buf write via win_we.
                S_HANN_WIN: begin
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_FFT_LOAD;
                    end
                end

                // ── Load windowed patch into FFT2D (TOTAL+1 cycles) ──────
                S_FFT_LOAD: begin
                    if (cnt_v) begin
                        fft_wr_addr    <= cnt_d;
                        fft_wr_data_re <= win_rd;
                        fft_wr_data_im <= {DATA_WIDTH{1'b0}};   // real input
                        fft_wr_en      <= 1'b1;
                    end
                    cnt_d <= cnt;
                    cnt_v <= 1'b1;
                    if (cnt != TOTAL-1)
                        cnt <= cnt + 1'b1;
                    if (cnt_v && cnt_d == TOTAL-1) begin
                        fft_start <= 1'b1;
                        cnt       <= {ADDR_W{1'b0}};
                        cnt_v     <= 1'b0;
                        state     <= S_FFT_RUN;
                    end
                end

                S_FFT_RUN: begin
                    if (fft_done) begin
                        cnt   <= {ADDR_W{1'b0}};
                        cnt_v <= 1'b0;
                        state <= S_ELEM_MUL;
                    end
                end

                // ── conj(alpha) ⊙ FFT(patch) (TOTAL+1 cycles) ────────────
                // fft_rd and alpha_rd align at cnt_d; mul write via mul_we.
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

                // ── Load product into IFFT2D (TOTAL+1 cycles) ────────────
                S_IFFT_LOAD: begin
                    if (cnt_v) begin
                        ifft_wr_addr    <= cnt_d;
                        ifft_wr_data_re <= mul_rd_re;
                        ifft_wr_data_im <= mul_rd_im;
                        ifft_wr_en      <= 1'b1;
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

                // ── Copy IFFT output into resp_map (TOTAL+1 cycles) ──────
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

                S_PEAK_WAIT: begin
                    if (pk_done) begin
                        peak_row <= pk_row;
                        peak_col <= pk_col;
                        peak_val <= pk_val;
                        state    <= S_DONE;
                    end
                end

                S_DONE: begin
                    done         <= 1'b1;
                    target_found <= ($signed(peak_val) > $signed(conf_threshold));
                    state        <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
