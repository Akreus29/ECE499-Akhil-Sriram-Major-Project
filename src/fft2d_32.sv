`timescale 1ns/1ps
// fft2d_32.sv
// 32×32 2D FFT via row-column decomposition.
// Pass 1: apply fft1d_32 to each of the 32 rows.
// Pass 2: apply fft1d_32 to each of the 32 columns of the result.
//
// SYNTHESIZABLE VERSION — buf_re/buf_im are true dual-port-style BRAMs:
//   - one synchronous write port (muxed: external load / row save / col save)
//   - one synchronous read port  (muxed: external read  / row load / col load)
//   - row/column transfers are serialized to ONE element per cycle
//
// Interface change vs. the original: rd_data_re/rd_data_im are REGISTERED —
// read data is valid ONE CYCLE after rd_addr is presented.
//
// Cycle count per line: load = N+1, save = N (was 1 each);
// full 2D FFT ≈ 2N·(2N+1+T_fft1d) cycles.

module fft2d_32 #(
    parameter N            = 32,
    parameter DATA_WIDTH   = 16,
    parameter FRAC         = 8,
    parameter SCALE_EN_ROW = 1,
    parameter SCALE_EN_COL = 1
)(
    input  wire                           clk,
    input  wire                           rst_n,
    // Write interface: load one element per cycle (accepted in IDLE only)
    input  wire [$clog2(N*N)-1:0]         wr_addr,
    input  wire signed [DATA_WIDTH-1:0]   wr_data_re,
    input  wire signed [DATA_WIDTH-1:0]   wr_data_im,
    input  wire                           wr_en,
    // Control
    input  wire                           start,
    // Read interface — REGISTERED: data valid 1 cycle after rd_addr
    input  wire [$clog2(N*N)-1:0]         rd_addr,
    output reg  signed [DATA_WIDTH-1:0]   rd_data_re,
    output reg  signed [DATA_WIDTH-1:0]   rd_data_im,
    output reg                            done
);

    localparam LOG2N  = $clog2(N);
    localparam ADDR_W = $clog2(N*N);

    // ── FSM ─────────────────────────────────────────────────────────────
    localparam S_IDLE     = 3'd0;
    localparam S_ROW_LOAD = 3'd1;
    localparam S_ROW_RUN  = 3'd2;
    localparam S_ROW_SAVE = 3'd3;
    localparam S_COL_LOAD = 3'd4;
    localparam S_COL_RUN  = 3'd5;
    localparam S_COL_SAVE = 3'd6;
    localparam S_DONE     = 3'd7;

    reg [2:0]        state;
    reg [LOG2N-1:0]  line_idx;   // current row or column

    // Serial-transfer counters
    reg [LOG2N-1:0]  ld_cnt;     // load address-issue counter
    reg [LOG2N-1:0]  ld_idx;     // element the arriving read data belongs to
    reg              ld_valid;   // read data this cycle is valid
    reg [LOG2N-1:0]  sv_cnt;     // save write counter

    // ── Interface arrays to fft1d (declared early — used in write mux) ──
    reg  signed [DATA_WIDTH-1:0] fft_in_re  [0:N-1];
    reg  signed [DATA_WIDTH-1:0] fft_in_im  [0:N-1];
    wire signed [DATA_WIDTH-1:0] fft_out_re [0:N-1];
    wire signed [DATA_WIDTH-1:0] fft_out_im [0:N-1];

    // ── Internal N×N complex buffer (BRAM) ──────────────────────────────
    reg signed [DATA_WIDTH-1:0] buf_re [0:N*N-1];
    reg signed [DATA_WIDTH-1:0] buf_im [0:N*N-1];

    // Read-address mux (combinational; BRAM output register below)
    reg [ADDR_W-1:0] buf_raddr;
    always @(*) begin
        case (state)
            S_ROW_LOAD: buf_raddr = {line_idx, ld_cnt};   // line*N + i
            S_COL_LOAD: buf_raddr = {ld_cnt, line_idx};   // i*N + line
            default:    buf_raddr = rd_addr;              // external read
        endcase
    end

    // Write-port mux (combinational)
    reg                         buf_we;
    reg [ADDR_W-1:0]            buf_waddr;
    reg signed [DATA_WIDTH-1:0] buf_wdata_re, buf_wdata_im;
    always @(*) begin
        case (state)
            S_ROW_SAVE: begin
                buf_we       = 1'b1;
                buf_waddr    = {line_idx, sv_cnt};
                buf_wdata_re = fft_out_re[sv_cnt];
                buf_wdata_im = fft_out_im[sv_cnt];
            end
            S_COL_SAVE: begin
                buf_we       = 1'b1;
                buf_waddr    = {sv_cnt, line_idx};
                buf_wdata_re = fft_out_re[sv_cnt];
                buf_wdata_im = fft_out_im[sv_cnt];
            end
            default: begin                                // external write (IDLE)
                buf_we       = wr_en && (state == S_IDLE);
                buf_waddr    = wr_addr;
                buf_wdata_re = wr_data_re;
                buf_wdata_im = wr_data_im;
            end
        endcase
    end

    // BRAM inference: synchronous write + synchronous (registered) read
    reg signed [DATA_WIDTH-1:0] buf_rd_re, buf_rd_im;
    always @(posedge clk) begin
        if (buf_we) begin
            buf_re[buf_waddr] <= buf_wdata_re;
            buf_im[buf_waddr] <= buf_wdata_im;
        end
        buf_rd_re <= buf_re[buf_raddr];
        buf_rd_im <= buf_im[buf_raddr];
    end

    // External read data = registered BRAM output (1-cycle latency)
    always @(*) begin
        rd_data_re = buf_rd_re;
        rd_data_im = buf_rd_im;
    end

    // ── Interface to fft1d_32 ───────────────────────────────────────────
    reg  fft_start;
    wire fft_done;
    reg  fft_scale_en;

    fft1d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_fft1d (
        .clk(clk), .rst_n(rst_n),
        .start(fft_start),
        .scale_en(fft_scale_en),
        .in_re(fft_in_re), .in_im(fft_in_im),
        .out_re(fft_out_re), .out_im(fft_out_im),
        .done(fft_done)
    );

    // ── Main FSM ────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            line_idx     <= {LOG2N{1'b0}};
            ld_cnt       <= {LOG2N{1'b0}};
            ld_idx       <= {LOG2N{1'b0}};
            ld_valid     <= 1'b0;
            sv_cnt       <= {LOG2N{1'b0}};
            fft_start    <= 1'b0;
            fft_scale_en <= 1'b1;
            done         <= 1'b0;
        end else begin
            fft_start <= 1'b0;
            done      <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        line_idx     <= {LOG2N{1'b0}};
                        fft_scale_en <= SCALE_EN_ROW[0];
                        ld_cnt       <= {LOG2N{1'b0}};
                        ld_valid     <= 1'b0;
                        state        <= S_ROW_LOAD;
                    end
                end

                // ── Row pass: stream row line_idx from BRAM into fft_in ──
                S_ROW_LOAD: begin
                    // Capture data that arrived for last cycle's address
                    if (ld_valid) begin
                        fft_in_re[ld_idx] <= buf_rd_re;
                        fft_in_im[ld_idx] <= buf_rd_im;
                    end
                    // Advance address pipeline
                    ld_idx   <= ld_cnt;
                    ld_valid <= 1'b1;
                    if (ld_cnt != N-1)
                        ld_cnt <= ld_cnt + 1'b1;
                    // Last element captured this cycle → run the 1D FFT
                    if (ld_valid && ld_idx == N-1) begin
                        fft_start <= 1'b1;
                        ld_valid  <= 1'b0;
                        state     <= S_ROW_RUN;
                    end
                end

                S_ROW_RUN: begin
                    if (fft_done) begin
                        sv_cnt <= {LOG2N{1'b0}};
                        state  <= S_ROW_SAVE;
                    end
                end

                // Write FFT result back one element per cycle (write mux above)
                S_ROW_SAVE: begin
                    if (sv_cnt == N-1) begin
                        ld_cnt   <= {LOG2N{1'b0}};
                        ld_valid <= 1'b0;
                        if (line_idx == N-1) begin
                            line_idx     <= {LOG2N{1'b0}};
                            fft_scale_en <= SCALE_EN_COL[0];
                            state        <= S_COL_LOAD;
                        end else begin
                            line_idx <= line_idx + 1'b1;
                            state    <= S_ROW_LOAD;
                        end
                    end else begin
                        sv_cnt <= sv_cnt + 1'b1;
                    end
                end

                // ── Column pass: stream column line_idx (strided) ────────
                S_COL_LOAD: begin
                    if (ld_valid) begin
                        fft_in_re[ld_idx] <= buf_rd_re;
                        fft_in_im[ld_idx] <= buf_rd_im;
                    end
                    ld_idx   <= ld_cnt;
                    ld_valid <= 1'b1;
                    if (ld_cnt != N-1)
                        ld_cnt <= ld_cnt + 1'b1;
                    if (ld_valid && ld_idx == N-1) begin
                        fft_start <= 1'b1;
                        ld_valid  <= 1'b0;
                        state     <= S_COL_RUN;
                    end
                end

                S_COL_RUN: begin
                    if (fft_done) begin
                        sv_cnt <= {LOG2N{1'b0}};
                        state  <= S_COL_SAVE;
                    end
                end

                S_COL_SAVE: begin
                    if (sv_cnt == N-1) begin
                        ld_cnt   <= {LOG2N{1'b0}};
                        ld_valid <= 1'b0;
                        if (line_idx == N-1) begin
                            state <= S_DONE;
                        end else begin
                            line_idx <= line_idx + 1'b1;
                            state    <= S_COL_LOAD;
                        end
                    end else begin
                        sv_cnt <= sv_cnt + 1'b1;
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
