`timescale 1ns/1ps
// ifft2d_64.sv
// 64×64 2D IFFT via conjugate trick:
//   IFFT(X) = conj( FFT( conj(X) ) ) / N^2
// The 1/N^2 normalization is skipped; peak location is scale-invariant.
//
// Interface matches ifft2d_32.sv exactly (wr/rd port style).

module ifft2d_64 #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
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

    localparam S_IDLE    = 2'd0;
    localparam S_CONJ_IN = 2'd1;
    localparam S_FFT_RUN = 2'd2;
    localparam S_DONE    = 2'd3;

    reg [1:0]  state;
    reg [11:0] conj_cnt;    // 0..4095

    // ── Internal FFT2D ──────────────────────────────────────────────────
    reg  [$clog2(N*N)-1:0]       fft_wr_addr;
    reg  signed [DATA_WIDTH-1:0] fft_wr_data_re;
    reg  signed [DATA_WIDTH-1:0] fft_wr_data_im;
    reg                          fft_wr_en;
    reg                          fft_start;
    wire                         fft_done;
    wire signed [DATA_WIDTH-1:0] fft_rd_re;
    wire signed [DATA_WIDTH-1:0] fft_rd_im;

    fft2d_64 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC),
               .SCALE_EN_ROW(1), .SCALE_EN_COL(1)) u_fft2d (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(fft_wr_addr),
        .wr_data_re(fft_wr_data_re),
        .wr_data_im(fft_wr_data_im),
        .wr_en(fft_wr_en),
        .start(fft_start),
        .rd_addr(rd_addr),
        .rd_data_re(fft_rd_re),
        .rd_data_im(fft_rd_im),
        .done(fft_done)
    );

    // Conjugate the FFT output to complete the IFFT
    assign rd_data_re =  fft_rd_re;
    assign rd_data_im = -fft_rd_im;

    // ── Input buffer ────────────────────────────────────────────────────
    reg signed [DATA_WIDTH-1:0] in_buf_re [0:N*N-1];
    reg signed [DATA_WIDTH-1:0] in_buf_im [0:N*N-1];

    // ── Main FSM ────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            conj_cnt  <= 0;
            fft_wr_en <= 0;
            fft_start <= 0;
            done      <= 0;
        end else begin
            fft_wr_en <= 0;
            fft_start <= 0;
            done      <= 0;

            case (state)

                S_IDLE: begin
                    if (wr_en) begin
                        in_buf_re[wr_addr] <= wr_data_re;
                        in_buf_im[wr_addr] <= wr_data_im;
                    end
                    if (start) begin
                        conj_cnt <= 0;
                        state    <= S_CONJ_IN;
                    end
                end

                // Feed conjugated input into FFT2D (1 element/cycle, 4096 cycles)
                S_CONJ_IN: begin
                    fft_wr_addr    <= conj_cnt;
                    fft_wr_data_re <=  in_buf_re[conj_cnt];
                    fft_wr_data_im <= -in_buf_im[conj_cnt];
                    fft_wr_en      <= 1;

                    if (conj_cnt == N*N - 1) begin
                        fft_start <= 1;
                        state     <= S_FFT_RUN;
                    end else begin
                        conj_cnt <= conj_cnt + 1;
                    end
                end

                S_FFT_RUN: begin
                    if (fft_done) state <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1;
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule
