`timescale 1ns/1ps
// =============================================================================
// ncc_search.sv
// Sliding-window normalized xcorr-correlation target acquisition.
//
// Searches the 4x-decimated frame (80×80, 8-bit) for the best match against
// the 16×16 zero-mean target template.  65×65 = 4225 window positions,
// stride 1.  Per position (256 serial MAC cycles):
//
//   xcorr = Σ  f(y+i, x+j) · (t(i,j) − t_mean)      (25-bit signed)
//   Ef    = Σ  f(y+i, x+j)²                          (24-bit unsigned)
//
// Normalized argmax WITHOUT per-position division — position A beats B iff
//   crossA² · EfB  >  crossB² · EfA      (template energy Et cancels)
// computed with wide registered multiplies (2-cycle compare).  Windows with
// xcorr ≤ 0 (anti-correlated) never win.
//
// Final confidence, once per frame (serial restoring divide, ~60 cycles):
//   conf_q88 = (cross_best² << 8) / (Ef_best · Et)   ∈ [0, 256] Q8.8
// (Cauchy–Schwarz guarantees cross² ≤ Ef·Et, so conf ≤ 1.0.)
//
// Memory interfaces are read-master ports into frame_input_if's BRAMs,
// both with 1-cycle read latency.
//
// Cycle count ≈ 4225 × 261 ≈ 1.10 M ≈ 22 ms @ 50 MHz.
// =============================================================================

module ncc_search #(
    parameter DEC_W   = 80,     // decimated frame width  (cols)
    parameter DEC_H   = 60,     // decimated frame height (rows)
    parameter TMPL_W  = 16,     // template is TMPL_W × TMPL_W
    // Window-position stride.  STRIDE=2 quarters the search time (~4 ms vs
    // ~16 ms) at a worst-case centre error of 1 decimated px = 4 full-res px
    // — well inside the 64×64 KCF crop that refines the position anyway.
    parameter STRIDE  = 2
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire               start,       // pulse
    output reg                busy,
    output reg                done,        // 1-cycle pulse

    // Decimated-frame read port (into frame_input_if; 1-cycle latency).
    // Addresses are COMBINATIONAL from the scan counters so total read
    // latency stays exactly one cycle (BRAM output register only).
    output wire [12:0]        dec_rd_addr,     // 0..6399
    input  wire [7:0]         dec_rd_data,

    // Template read port (into frame_input_if; 1-cycle latency, zero-mean)
    output wire [7:0]         tmpl_rd_addr,    // 0..255
    input  wire signed [8:0]  tmpl_rd_data,    // t − mean
    input  wire [25:0]        tmpl_energy,     // Et = Σ(t−mean)²

    // Result
    output reg  [6:0]         best_row,    // decimated coords: window top-left
    output reg  [6:0]         best_col,
    output reg  [15:0]        confidence,  // Q8.8, 0..0x0100
    output reg                found_any    // at least one positive-xcorr window
);

    localparam POS_MAX_X = DEC_W - TMPL_W;    // 64 → cols 0..64 (65 positions)
    localparam POS_MAX_Y = DEC_H - TMPL_W;    // 44 → rows 0..44 (45 positions)
    localparam WIN_PIX   = TMPL_W * TMPL_W;   // 256

    // FSM
    localparam S_IDLE   = 3'd0;
    localparam S_SCAN   = 3'd1;   // stream one window (256 pixels + pipeline)
    localparam S_SQ     = 3'd2;   // register cross², xcorr-products
    localparam S_CMP    = 3'd3;   // compare and update best
    localparam S_NEXT   = 3'd4;   // advance window position
    localparam S_DIV    = 3'd5;   // final confidence division
    localparam S_DONE   = 3'd6;

    reg [2:0] state;

    // Window position
    reg [6:0] win_y, win_x;

    // Inner-window scan
    reg [8:0] scan_i;          // 0..256 issue counter
    reg [8:0] scan_d;          // delayed (data phase)
    reg       scan_v;

    // Accumulators
    reg signed [24:0] xcorr;
    reg        [23:0] ef;

    // Best-so-far
    reg [47:0] best_cross_sq;
    reg [23:0] best_ef;

    // Wide compare pipeline
    reg [47:0] cand_cross_sq;
    reg [71:0] lhs, rhs;       // cand² · best_ef  vs  best² · cand_ef
    reg [23:0] cand_ef;
    reg        cand_positive;

    // Confidence divider: num = best_cross_sq << 8 (56b), den = best_ef · Et (50b)
    reg [55:0] div_num;
    reg [49:0] div_den;
    reg [55:0] div_rem;
    reg [15:0] div_quo;
    reg [5:0]  div_cnt;

    // MAC operand wires (data phase)
    wire [7:0]        f_pix  = dec_rd_data;
    wire signed [8:0] t_pix  = tmpl_rd_data;
    wire signed [17:0] prod  = $signed({1'b0, f_pix}) * t_pix;   // 9×9 signed
    wire [15:0]        f_sq  = f_pix * f_pix;

    // Address generation: dec addr = (win_y + i[7:4]) * 80 + (win_x + i[3:0]).
    // Driven combinationally onto the read ports.
    wire [6:0] pix_row = win_y + scan_i[7:4];
    wire [6:0] pix_col = win_x + scan_i[3:0];
    assign dec_rd_addr  = ({6'd0, pix_row} << 6) + ({6'd0, pix_row} << 4)
                        + {6'd0, pix_col};
    assign tmpl_rd_addr = scan_i[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            win_y         <= 7'd0;
            win_x         <= 7'd0;
            scan_i        <= 9'd0;
            scan_d        <= 9'd0;
            scan_v        <= 1'b0;
            xcorr         <= 25'sd0;
            ef            <= 24'd0;
            best_cross_sq <= 48'd0;
            best_ef       <= 24'd1;      // avoid 0 in compare products
            cand_cross_sq <= 48'd0;
            cand_ef       <= 24'd0;
            cand_positive <= 1'b0;
            lhs           <= 72'd0;
            rhs           <= 72'd0;
            best_row      <= 7'd0;
            best_col      <= 7'd0;
            confidence    <= 16'd0;
            found_any     <= 1'b0;
            div_num       <= 56'd0;
            div_den       <= 50'd0;
            div_rem       <= 56'd0;
            div_quo       <= 16'd0;
            div_cnt       <= 6'd0;
        end else begin
            done <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        busy          <= 1'b1;
                        win_y         <= 7'd0;
                        win_x         <= 7'd0;
                        best_cross_sq <= 48'd0;
                        best_ef       <= 24'd1;
                        found_any     <= 1'b0;
                        scan_i        <= 9'd0;
                        scan_v        <= 1'b0;
                        xcorr         <= 25'sd0;
                        ef            <= 24'd0;
                        state         <= S_SCAN;
                    end
                end

                // ── Stream one 16×16 window, addr/data pipelined ────────────
                // Addresses are combinational from scan_i; data for scan_d
                // arrives one cycle later (BRAM output register).
                S_SCAN: begin
                    if (scan_i < WIN_PIX[8:0]) begin
                        scan_i <= scan_i + 9'd1;
                    end
                    // Data phase: accumulate for scan_d
                    scan_d <= scan_i;
                    scan_v <= (scan_i < WIN_PIX[8:0]);
                    if (scan_v) begin
                        xcorr <= xcorr + prod;
                        ef    <= ef + {8'd0, f_sq};
                    end
                    // Last data consumed when scan_v covers index 255
                    if (scan_v && scan_d == WIN_PIX[8:0] - 9'd1) begin
                        scan_v <= 1'b0;
                        state  <= S_SQ;
                    end
                end

                // ── Square the correlation (registered for timing) ─────────
                S_SQ: begin
                    if (xcorr[24]) begin
                        // Negative correlation — never a candidate
                        cand_positive <= 1'b0;
                        cand_cross_sq <= 48'd0;
                    end else begin
                        cand_positive <= (xcorr != 0);
                        cand_cross_sq <= xcorr[23:0] * xcorr[23:0];
                    end
                    cand_ef <= (ef == 0) ? 24'd1 : ef;
                    state   <= S_CMP;
                end

                // ── Cross-multiplied normalized comparison ─────────────────
                S_CMP: begin
                    lhs   <= cand_cross_sq * best_ef;    // candidate score
                    rhs   <= best_cross_sq * cand_ef;    // incumbent score
                    state <= S_NEXT;
                end

                S_NEXT: begin
                    if (cand_positive && (lhs > rhs)) begin
                        best_cross_sq <= cand_cross_sq;
                        best_ef       <= cand_ef;
                        best_row      <= win_y;
                        best_col      <= win_x;
                        found_any     <= 1'b1;
                    end
                    // Reset window accumulators
                    xcorr  <= 25'sd0;
                    ef     <= 24'd0;
                    scan_i <= 9'd0;
                    scan_v <= 1'b0;
                    // Advance position (rectangular grid, STRIDE steps)
                    if (win_x + STRIDE[6:0] > POS_MAX_X[6:0]) begin
                        win_x <= 7'd0;
                        if (win_y + STRIDE[6:0] > POS_MAX_Y[6:0]) begin
                            // All positions done → confidence division
                            div_num <= {best_cross_sq, 8'd0};
                            div_den <= best_ef * tmpl_energy;
                            div_rem <= 56'd0;
                            div_quo <= 16'd0;
                            div_cnt <= 6'd55;
                            state   <= S_DIV;
                        end else begin
                            win_y <= win_y + STRIDE[6:0];
                            state <= S_SCAN;
                        end
                    end else begin
                        win_x <= win_x + STRIDE[6:0];
                        state <= S_SCAN;
                    end
                end

                // ── Serial restoring division: conf = num / den ────────────
                // num = best_cross² << 8, den = best_ef · Et.
                // Quotient ≤ 256 by Cauchy–Schwarz; clamp into 16 bits anyway.
                S_DIV: begin : div_step
                    reg [56:0] rem_shift;
                    rem_shift = {div_rem[54:0], div_num[div_cnt]};
                    if (rem_shift >= {7'd0, div_den}) begin
                        div_rem <= rem_shift[55:0] - {6'd0, div_den};
                        div_quo <= {div_quo[14:0], 1'b1};
                    end else begin
                        div_rem <= rem_shift[55:0];
                        div_quo <= {div_quo[14:0], 1'b0};
                    end
                    if (div_cnt == 0) begin
                        state <= S_DONE;
                    end else
                        div_cnt <= div_cnt - 6'd1;
                end

                S_DONE: begin
                    confidence <= found_any ? ((div_quo > 16'h0100) ? 16'h0100
                                                                    : div_quo)
                                            : 16'd0;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
