`timescale 1ns/1ps
// seq_div.sv
// Sequential complex-by-real divider — synthesizable replacement for the
// combinational divider in cdiv.sv.
//
//   out_re = num_re / (denom_re + lambda)
//   out_im = num_im / (denom_re + lambda)
//
// Same math as cdiv.sv: computes recip = 65536 / d  (Q8.8 reciprocal of a
// Q8.8 value, since 65536 = 2^(2*FRAC)), then two DSP multiplies.
// The divide is a restoring divider producing one quotient bit per cycle:
//   17 divide cycles + 1 setup + 1 multiply/latch  ≈ 19 cycles per element.
//
// Handshake:
//   - Pulse `start` with operands held stable; `busy` rises next cycle.
//   - `done` pulses for exactly 1 cycle; outputs are valid on that cycle
//     and hold their values until the next start.
//
// Used in kcf_top for the Wiener-filter update  alpha = Y_hat / (X_hat + λ).

module seq_div #(
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire                          start,
    input  wire signed [DATA_WIDTH-1:0]  num_re,
    input  wire signed [DATA_WIDTH-1:0]  num_im,
    input  wire signed [DATA_WIDTH-1:0]  denom_re,  // real denominator (K_hat)
    input  wire signed [DATA_WIDTH-1:0]  lambda,    // regularisation constant

    output reg  signed [DATA_WIDTH-1:0]  out_re,
    output reg  signed [DATA_WIDTH-1:0]  out_im,
    output reg                           div_by_zero,
    output reg                           busy,
    output reg                           done
);

    // Dividend 2^(2*FRAC) = 65536 needs 17 bits; quotient fits in 17 bits
    // (worst case d = 1 → q = 65536).
    localparam QW = 2*FRAC + 1;   // 17 quotient bits

    localparam S_IDLE = 2'd0;
    localparam S_DIV  = 2'd1;
    localparam S_MUL  = 2'd2;

    reg [1:0]              state;
    reg [4:0]              bit_cnt;                 // counts QW-1 .. 0
    reg [DATA_WIDTH-1:0]   divisor;                 // d (positive)
    reg [QW+DATA_WIDTH-1:0] rem;                    // partial remainder
    reg [QW-1:0]           quot;                    // quotient accumulator
    reg signed [DATA_WIDTH-1:0] num_re_lat, num_im_lat;

    // Restoring division step (combinational):
    //   shift remainder left, bring in next dividend bit, try subtract.
    // Dividend is the constant 65536 = 1 << (2*FRAC): bit (QW-1) is 1,
    // bits below are 0.
    wire dividend_bit = (bit_cnt == QW-1);          // MSB first: only bit 16 set
    wire [QW+DATA_WIDTH-1:0] rem_shift = {rem[QW+DATA_WIDTH-2:0], dividend_bit};
    wire [QW+DATA_WIDTH-1:0] rem_sub   = rem_shift - {{QW{1'b0}}, divisor};
    wire sub_ok = (rem_shift >= {{QW{1'b0}}, divisor});

    // Q8.8 reciprocal from quotient (truncate to DATA_WIDTH like cdiv did)
    wire signed [DATA_WIDTH-1:0] recip = quot[DATA_WIDTH-1:0];

    // Multiply stage (2 DSP): same truncation window as cdiv.sv [FRAC+DW-1:FRAC]
    wire signed [2*DATA_WIDTH-1:0] re_full = num_re_lat * recip;
    wire signed [2*DATA_WIDTH-1:0] im_full = num_im_lat * recip;

    // Denominator preprocessing (same guard as cdiv.sv)
    wire signed [DATA_WIDTH:0] d_full = $signed(denom_re) + $signed(lambda);
    wire                       d_bad  = (d_full <= 0);
    wire [DATA_WIDTH-1:0]      d_pos  = d_bad ? 16'd1 : d_full[DATA_WIDTH-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            bit_cnt     <= 5'd0;
            divisor     <= {DATA_WIDTH{1'b0}};
            rem         <= {(QW+DATA_WIDTH){1'b0}};
            quot        <= {QW{1'b0}};
            num_re_lat  <= {DATA_WIDTH{1'b0}};
            num_im_lat  <= {DATA_WIDTH{1'b0}};
            out_re      <= {DATA_WIDTH{1'b0}};
            out_im      <= {DATA_WIDTH{1'b0}};
            div_by_zero <= 1'b0;
            busy        <= 1'b0;
            done        <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        divisor     <= d_pos;
                        div_by_zero <= d_bad;
                        num_re_lat  <= num_re;
                        num_im_lat  <= num_im;
                        rem         <= {(QW+DATA_WIDTH){1'b0}};
                        quot        <= {QW{1'b0}};
                        bit_cnt     <= QW - 1;
                        busy        <= 1'b1;
                        state       <= S_DIV;
                    end
                end

                S_DIV: begin
                    // One restoring-division step per cycle, MSB first
                    if (sub_ok) begin
                        rem  <= rem_sub;
                        quot <= {quot[QW-2:0], 1'b1};
                    end else begin
                        rem  <= rem_shift;
                        quot <= {quot[QW-2:0], 1'b0};
                    end

                    if (bit_cnt == 0)
                        state <= S_MUL;
                    else
                        bit_cnt <= bit_cnt - 5'd1;
                end

                S_MUL: begin
                    // recip is stable; latch truncated products (cdiv-identical)
                    out_re <= div_by_zero ? {DATA_WIDTH{1'b0}}
                                          : re_full[FRAC+DATA_WIDTH-1:FRAC];
                    out_im <= div_by_zero ? {DATA_WIDTH{1'b0}}
                                          : im_full[FRAC+DATA_WIDTH-1:FRAC];
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
