`timescale 1ns/1ps
// kcf_detect_top.v
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
//   7. PEAK_RUN  — copy IFFT output to response map, find peak

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
    // Detection output
    output reg  [$clog2(N)-1:0]           peak_row,
    output reg  [$clog2(N)-1:0]           peak_col,
    output reg  signed [DATA_WIDTH-1:0]   peak_val,
    output reg                            done
);

    localparam TOTAL = N * N;        // 1024

    // ── FSM states ──────────────────────────────────────────────────────
    localparam S_IDLE      = 4'd0;
    localparam S_HANN_WIN  = 4'd1;
    localparam S_FFT_LOAD  = 4'd2;
    localparam S_FFT_RUN   = 4'd3;
    localparam S_ELEM_MUL  = 4'd4;
    localparam S_IFFT_LOAD = 4'd5;
    localparam S_IFFT_RUN  = 4'd6;
    localparam S_PEAK_RUN  = 4'd7;
    localparam S_DONE      = 4'd8;

    reg [3:0]  state;
    reg [10:0] cnt;             // 11-bit counter to hold 0..1024 for pipeline flush

    // ── Input patch buffer ──────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] patch_buf [0:TOTAL-1];

    // ── Windowed patch buffer ───────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] win_buf_re [0:TOTAL-1];

    // ── Hann ROM ────────────────────────────────────────────────────────
    // FIX for Bug A: addresses are combinational wires, not registers.
    // This ensures ROM output is valid in the same cycle.
    wire [$clog2(N)-1:0] hann_addr_r = cnt[9:0] / N;
    wire [$clog2(N)-1:0] hann_addr_c = cnt[9:0] % N;
    wire [DATA_WIDTH-1:0] hann_val_r, hann_val_c;

    hann_rom_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_hann_r (
        .addr(hann_addr_r), .w_out(hann_val_r)
    );
    hann_rom_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH)) u_hann_c (
        .addr(hann_addr_c), .w_out(hann_val_c)
    );

    // ── Alpha hat ROM (frozen filter) ───────────────────────────────────
    reg signed [DATA_WIDTH-1:0] alpha_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] alpha_im [0:TOTAL-1];

    // Load from interleaved .mem file
    reg signed [DATA_WIDTH-1:0] alpha_flat [0:2*TOTAL-1];
    integer init_i;
    initial begin
        $readmemh("data/alpha_hat.mem", alpha_flat);
        for (init_i = 0; init_i < TOTAL; init_i = init_i + 1) begin
            alpha_re[init_i] = alpha_flat[2*init_i];
            alpha_im[init_i] = alpha_flat[2*init_i + 1];
        end
    end

    // ── FFT2D instance ──────────────────────────────────────────────────
    reg  [$clog2(TOTAL)-1:0]        fft_wr_addr;
    reg  signed [DATA_WIDTH-1:0]    fft_wr_data_re, fft_wr_data_im;
    reg                             fft_wr_en, fft_start;
    wire                            fft_done;
    // FIX for Bug B: fft_rd_addr is a combinational wire
    wire [$clog2(TOTAL)-1:0]        fft_rd_addr = cnt[9:0];
    wire signed [DATA_WIDTH-1:0]    fft_rd_re, fft_rd_im;

    fft2d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC), .SCALE_EN(1)) u_fft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(fft_wr_addr), .wr_data_re(fft_wr_data_re),
        .wr_data_im(fft_wr_data_im), .wr_en(fft_wr_en),
        .start(fft_start),
        .rd_addr(fft_rd_addr), .rd_data_re(fft_rd_re), .rd_data_im(fft_rd_im),
        .done(fft_done)
    );

    // ── Conjugate multiplier (one instance, reused iteratively) ─────────
    // FIX for Bug B: inputs are combinational wires, not registers
    wire signed [DATA_WIDTH-1:0] cmul_a_re = alpha_re[cnt[9:0]];
    wire signed [DATA_WIDTH-1:0] cmul_a_im = alpha_im[cnt[9:0]];
    wire signed [DATA_WIDTH-1:0] cmul_b_re = fft_rd_re;
    wire signed [DATA_WIDTH-1:0] cmul_b_im = fft_rd_im;
    wire signed [DATA_WIDTH-1:0] cmul_out_re, cmul_out_im;

    cconj_mul #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cconj (
        .a_re(cmul_a_re), .a_im(cmul_a_im),
        .b_re(cmul_b_re), .b_im(cmul_b_im),
        .out_re(cmul_out_re), .out_im(cmul_out_im)
    );

    // ── Element-multiply result buffer ──────────────────────────────────
    reg signed [DATA_WIDTH-1:0] mul_buf_re [0:TOTAL-1];
    reg signed [DATA_WIDTH-1:0] mul_buf_im [0:TOTAL-1];

    // ── IFFT2D instance ─────────────────────────────────────────────────
    reg  [$clog2(TOTAL)-1:0]        ifft_wr_addr;
    reg  signed [DATA_WIDTH-1:0]    ifft_wr_data_re, ifft_wr_data_im;
    reg                             ifft_wr_en, ifft_start;
    wire                            ifft_done;
    reg  [$clog2(TOTAL)-1:0]        ifft_rd_addr;
    wire signed [DATA_WIDTH-1:0]    ifft_rd_re, ifft_rd_im;

    ifft2d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_ifft (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(ifft_wr_addr), .wr_data_re(ifft_wr_data_re),
        .wr_data_im(ifft_wr_data_im), .wr_en(ifft_wr_en),
        .start(ifft_start),
        .rd_addr(ifft_rd_addr), .rd_data_re(ifft_rd_re), .rd_data_im(ifft_rd_im),
        .done(ifft_done)
    );

    // ── Peak finder ─────────────────────────────────────────────────────
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

    // ── Hann windowing intermediates (all combinational) ────────────────
    // Q8.8 × Q8.8 → Q16.16, keep [23:8] → Q8.8
    wire signed [2*DATA_WIDTH-1:0] hann_prod = $signed({1'b0, hann_val_r}) * $signed({1'b0, hann_val_c});
    wire signed [DATA_WIDTH-1:0]   hann_2d   = hann_prod[FRAC+DATA_WIDTH-1:FRAC];
    wire signed [2*DATA_WIDTH-1:0] win_prod  = patch_buf[cnt[9:0]] * hann_2d;
    wire signed [DATA_WIDTH-1:0]   win_val   = win_prod[FRAC+DATA_WIDTH-1:FRAC];

    // ── Main FSM ────────────────────────────────────────────────────────
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            cnt        <= 0;
            fft_wr_en  <= 0;
            fft_start  <= 0;
            ifft_wr_en <= 0;
            ifft_start <= 0;
            pk_start   <= 0;
            done       <= 0;
        end else begin
            // Defaults
            fft_wr_en  <= 0;
            fft_start  <= 0;
            ifft_wr_en <= 0;
            ifft_start <= 0;
            pk_start   <= 0;
            done       <= 0;

            case (state)

                // ── Accept patch writes ─────────────────────────────────
                S_IDLE: begin
                    if (patch_wr_en)
                        patch_buf[patch_addr] <= patch_data;
                    if (start) begin
                        cnt   <= 0;
                        state <= S_HANN_WIN;
                    end
                end

                // ── Apply 2D Hann window: 1 pixel per cycle ─────────────
                // hann_addr_r/c are combinational wires from cnt,
                // so ROM outputs and win_val are valid same cycle.
                S_HANN_WIN: begin
                    win_buf_re[cnt[9:0]] <= win_val;

                    if (cnt == TOTAL - 1) begin
                        cnt   <= 0;
                        state <= S_FFT_LOAD;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // ── Load windowed patch into FFT2D ──────────────────────
                S_FFT_LOAD: begin
                    fft_wr_addr    <= cnt[9:0];
                    fft_wr_data_re <= win_buf_re[cnt[9:0]];
                    fft_wr_data_im <= 0;            // real input
                    fft_wr_en      <= 1;

                    if (cnt == TOTAL - 1) begin
                        fft_start <= 1;
                        cnt       <= 0;
                        state     <= S_FFT_RUN;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // ── Wait for FFT2D ──────────────────────────────────────
                S_FFT_RUN: begin
                    if (fft_done) begin
                        cnt   <= 0;
                        state <= S_ELEM_MUL;
                    end
                end

                // ── Element-wise conj(alpha) * FFT(patch) ───────────────
                // FIX for Bugs B & C:
                // fft_rd_addr and cmul inputs are combinational wires,
                // so cmul_out is valid combinationally from cnt.
                // Store result directly. Counter goes to TOTAL-1 (not TOTAL).
                S_ELEM_MUL: begin
                    mul_buf_re[cnt[9:0]] <= cmul_out_re;
                    mul_buf_im[cnt[9:0]] <= cmul_out_im;

                    if (cnt == TOTAL - 1) begin
                        cnt   <= 0;
                        state <= S_IFFT_LOAD;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // ── Load product into IFFT2D ────────────────────────────
                S_IFFT_LOAD: begin
                    ifft_wr_addr    <= cnt[9:0];
                    ifft_wr_data_re <= mul_buf_re[cnt[9:0]];
                    ifft_wr_data_im <= mul_buf_im[cnt[9:0]];
                    ifft_wr_en      <= 1;

                    if (cnt == TOTAL - 1) begin
                        ifft_start <= 1;
                        cnt        <= 0;
                        state      <= S_IFFT_RUN;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // ── Wait for IFFT2D ─────────────────────────────────────
                S_IFFT_RUN: begin
                    if (ifft_done) begin
                        cnt   <= 0;
                        state <= S_PEAK_RUN;
                    end
                end

                // ── Copy IFFT output to response map, then run peak finder
                // ifft_rd_addr is registered, so read is 1-cycle delayed.
                // Store at cnt-1, with an extra cycle to flush the last element.
                S_PEAK_RUN: begin
                    if (cnt < TOTAL) begin
                        ifft_rd_addr <= cnt[9:0];
                        if (cnt > 0)
                            resp_map[cnt[9:0] - 1] <= ifft_rd_re;
                        cnt <= cnt + 1;
                    end else if (cnt == TOTAL) begin
                        resp_map[TOTAL - 1] <= ifft_rd_re;
                        pk_start <= 1;
                        cnt      <= cnt + 1;
                    end else begin
                        if (pk_done) begin
                            peak_row <= pk_row;
                            peak_col <= pk_col;
                            peak_val <= pk_val;
                            state    <= S_DONE;
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
