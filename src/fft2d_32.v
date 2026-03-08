`timescale 1ns/1ps
// fft2d_32.v
// 32×32 2D FFT via row-column decomposition.
// Pass 1: apply fft1d_32 to each of the 32 rows.
// Pass 2: apply fft1d_32 to each of the 32 columns of the result.
//
// Interface: write data one element at a time via wr_addr/wr_data,
// then pulse start. Read results via rd_addr after done.

module fft2d_32 #(
    parameter N          = 32,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8,
    parameter SCALE_EN   = 1
)(
    input  wire                           clk,
    input  wire                           rst_n,
    // Write interface: load one element per cycle
    input  wire [$clog2(N*N)-1:0]         wr_addr,
    input  wire signed [DATA_WIDTH-1:0]   wr_data_re,
    input  wire signed [DATA_WIDTH-1:0]   wr_data_im,
    input  wire                           wr_en,
    // Control
    input  wire                           start,
    // Read interface
    input  wire [$clog2(N*N)-1:0]         rd_addr,
    output wire signed [DATA_WIDTH-1:0]   rd_data_re,
    output wire signed [DATA_WIDTH-1:0]   rd_data_im,
    output reg                            done
);

    // ── Internal 32×32 complex buffer ───────────────────────────────────
    reg signed [DATA_WIDTH-1:0] buf_re [0:N*N-1];
    reg signed [DATA_WIDTH-1:0] buf_im [0:N*N-1];

    // Read port (combinational)
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

    reg [2:0]  state;
    reg [4:0]  line_idx;     // current row or column (0..31)

    // ── Interface to fft1d_32 ───────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0]  fft_in_re [0:N-1];
    reg signed [DATA_WIDTH-1:0]  fft_in_im [0:N-1];
    wire signed [DATA_WIDTH-1:0] fft_out_re [0:N-1];
    wire signed [DATA_WIDTH-1:0] fft_out_im [0:N-1];
    reg  fft_start;
    wire fft_done;

    fft1d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC), .SCALE_EN(SCALE_EN)) u_fft1d (
        .clk(clk), .rst_n(rst_n),
        .start(fft_start),
        .in_re(fft_in_re), .in_im(fft_in_im),
        .out_re(fft_out_re), .out_im(fft_out_im),
        .done(fft_done)
    );

    // ── Main FSM ────────────────────────────────────────────────────────
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            line_idx  <= 0;
            fft_start <= 0;
            done      <= 0;
        end else begin
            fft_start <= 0;
            done      <= 0;

            case (state)

                S_IDLE: begin
                    // Accept writes while idle
                    if (wr_en) begin
                        buf_re[wr_addr] <= wr_data_re;
                        buf_im[wr_addr] <= wr_data_im;
                    end
                    if (start) begin
                        line_idx <= 0;
                        state    <= S_ROW_LOAD;
                    end
                end

                // ── Row pass ────────────────────────────────────────────
                // Copy row line_idx from buf into fft_in
                S_ROW_LOAD: begin
                    for (i = 0; i < N; i = i + 1) begin
                        fft_in_re[i] <= buf_re[line_idx * N + i];
                        fft_in_im[i] <= buf_im[line_idx * N + i];
                    end
                    fft_start <= 1;
                    state     <= S_ROW_RUN;
                end

                // Wait for fft1d_32 to finish
                S_ROW_RUN: begin
                    if (fft_done) begin
                        state <= S_ROW_SAVE;
                    end
                end

                // Write FFT result back into buf for this row
                S_ROW_SAVE: begin
                    for (i = 0; i < N; i = i + 1) begin
                        buf_re[line_idx * N + i] <= fft_out_re[i];
                        buf_im[line_idx * N + i] <= fft_out_im[i];
                    end
                    if (line_idx == N - 1) begin
                        // All rows done → start column pass
                        line_idx <= 0;
                        state    <= S_COL_LOAD;
                    end else begin
                        line_idx <= line_idx + 1;
                        state    <= S_ROW_LOAD;
                    end
                end

                // ── Column pass ─────────────────────────────────────────
                // Copy column line_idx from buf into fft_in (strided)
                S_COL_LOAD: begin
                    for (i = 0; i < N; i = i + 1) begin
                        fft_in_re[i] <= buf_re[i * N + line_idx];
                        fft_in_im[i] <= buf_im[i * N + line_idx];
                    end
                    fft_start <= 1;
                    state     <= S_COL_RUN;
                end

                S_COL_RUN: begin
                    if (fft_done) begin
                        state <= S_COL_SAVE;
                    end
                end

                // Write FFT result back (strided)
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
