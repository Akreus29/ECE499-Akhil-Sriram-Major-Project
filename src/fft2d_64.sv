`timescale 1ns/1ps
// fft2d_64.sv
// 64×64 2D FFT via row-column decomposition.
// Pass 1: apply fft1d_64 to each of the 64 rows.
// Pass 2: apply fft1d_64 to each of the 64 columns of the result.
//
// Interface matches fft2d_32.sv exactly; only N and counter widths change.

module fft2d_64 #(
    parameter N            = 64,
    parameter DATA_WIDTH   = 16,
    parameter FRAC         = 8,
    parameter SCALE_EN_ROW = 1,
    parameter SCALE_EN_COL = 1
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire [$clog2(N*N)-1:0]         wr_addr,
    input  wire signed [DATA_WIDTH-1:0]   wr_data_re,
    input  wire signed [DATA_WIDTH-1:0]   wr_data_im,
    input  wire                           wr_en,
    input  wire                           start,
    input  wire [$clog2(N*N)-1:0]         rd_addr,
    output wire signed [DATA_WIDTH-1:0]   rd_data_re,
    output wire signed [DATA_WIDTH-1:0]   rd_data_im,
    output reg                            done
);

    // ── Internal 64×64 complex buffer ───────────────────────────────────
    reg signed [DATA_WIDTH-1:0] buf_re [0:N*N-1];
    reg signed [DATA_WIDTH-1:0] buf_im [0:N*N-1];

    assign rd_data_re = buf_re[rd_addr];
    assign rd_data_im = buf_im[rd_addr];

    // ── FSM ─────────────────────────────────────────────────────────────
    localparam S_IDLE     = 3'd0;
    localparam S_ROW_LOAD = 3'd1;
    localparam S_ROW_RUN  = 3'd2;
    localparam S_ROW_SAVE = 3'd3;
    localparam S_COL_LOAD = 3'd4;
    localparam S_COL_RUN  = 3'd5;
    localparam S_COL_SAVE = 3'd6;
    localparam S_DONE     = 3'd7;

    reg [2:0] state;
    reg [5:0] line_idx;     // 0..63

    // ── Interface to fft1d_64 ───────────────────────────────────────────
    reg  signed [DATA_WIDTH-1:0] fft_in_re  [0:N-1];
    reg  signed [DATA_WIDTH-1:0] fft_in_im  [0:N-1];
    wire signed [DATA_WIDTH-1:0] fft_out_re [0:N-1];
    wire signed [DATA_WIDTH-1:0] fft_out_im [0:N-1];
    reg  fft_start;
    wire fft_done;
    reg  fft_scale_en;

    fft1d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_fft1d (
        .clk(clk), .rst_n(rst_n),
        .start(fft_start),
        .scale_en(fft_scale_en),
        .in_re(fft_in_re), .in_im(fft_in_im),
        .out_re(fft_out_re), .out_im(fft_out_im),
        .done(fft_done)
    );

    // ── Main FSM ────────────────────────────────────────────────────────
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            line_idx     <= 0;
            fft_start    <= 0;
            fft_scale_en <= 1;
            done         <= 0;
        end else begin
            fft_start <= 0;
            done      <= 0;

            case (state)

                S_IDLE: begin
                    if (wr_en) begin
                        buf_re[wr_addr] <= wr_data_re;
                        buf_im[wr_addr] <= wr_data_im;
                    end
                    if (start) begin
                        line_idx     <= 0;
                        fft_scale_en <= SCALE_EN_ROW[0];
                        state        <= S_ROW_LOAD;
                    end
                end

                S_ROW_LOAD: begin
                    for (i = 0; i < N; i = i + 1) begin
                        fft_in_re[i] <= buf_re[line_idx * N + i];
                        fft_in_im[i] <= buf_im[line_idx * N + i];
                    end
                    fft_start <= 1;
                    state     <= S_ROW_RUN;
                end

                S_ROW_RUN: begin
                    if (fft_done) state <= S_ROW_SAVE;
                end

                S_ROW_SAVE: begin
                    for (i = 0; i < N; i = i + 1) begin
                        buf_re[line_idx * N + i] <= fft_out_re[i];
                        buf_im[line_idx * N + i] <= fft_out_im[i];
                    end
                    if (line_idx == N - 1) begin
                        line_idx     <= 0;
                        fft_scale_en <= SCALE_EN_COL[0];
                        state        <= S_COL_LOAD;
                    end else begin
                        line_idx <= line_idx + 1;
                        state    <= S_ROW_LOAD;
                    end
                end

                S_COL_LOAD: begin
                    for (i = 0; i < N; i = i + 1) begin
                        fft_in_re[i] <= buf_re[i * N + line_idx];
                        fft_in_im[i] <= buf_im[i * N + line_idx];
                    end
                    fft_start <= 1;
                    state     <= S_COL_RUN;
                end

                S_COL_RUN: begin
                    if (fft_done) state <= S_COL_SAVE;
                end

                S_COL_SAVE: begin
                    for (i = 0; i < N; i = i + 1) begin
                        buf_re[i * N + line_idx] <= fft_out_re[i];
                        buf_im[i * N + line_idx] <= fft_out_im[i];
                    end
                    if (line_idx == N - 1) begin
                        state <= S_DONE;
                    end else begin
                        line_idx <= line_idx + 1;
                        state    <= S_COL_LOAD;
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
