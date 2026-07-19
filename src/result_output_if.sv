`timescale 1ns/1ps
// =============================================================================
// result_output_if.sv                                  (ICD v2 — OUTPUT SIDE)
//
// THE output interface file.  Everything the SHAKTI side reads FROM the IP
// lives here: the AXI4-Lite read channels (AR/R) and the complete register
// read decode.  A collaborator modelling the IP→SoC direction needs only
// this file.
//
// ── Read map (ICD v2 §2) — address decode addr[5:2] ───────────────────────
//
//   0x00  CTRL         reads 0 (write-only command register)
//   0x04  MODE         [1:0]   0=AUTO, 1=NCC only, 2=KCF only
//   0x08  THRESH       [15:0]  Q8.8 signed, sign-extended
//   0x0C  LAMBDA       [15:0]  Q8.8 signed, sign-extended
//   0x10  STATUS       [0] busy · [1] done · [3:2] algo (0=NCC, 1=KCF)
//                      · [4] tracking (KCF lock active)
//   0x14  ABS_ROW      [8:0]   absolute target centre row, 0..319
//   0x18  ABS_COL      [8:0]   absolute target centre col, 0..319
//   0x1C  CONFIDENCE   [15:0]  Q8.8 signed, sign-extended
//                              (NCC² score in acquisition, KCF peak in lock)
//   0x20  IRQ_MASK     [0]     reserved v2 (poll mode)
//   0x24  IRQ_STAT     [0]     reserved v2
//   0x28  IMAGE_FRAME  reads 0 (write-only)
//   0x2C  TARGET_POS   {col[24:16], row[8:0]}  designation centre read-back
//   0x30  BUF_IDX      [16:0]  frame-buffer pixel index, 0..102400
//   0x34–0x3C          read 0 (reserved)
//
// Zero-latency reads: ARREADY and RVALID assert in the same cycle as
// ARVALID; RVALID held until RREADY (single outstanding transaction).
// =============================================================================

module result_output_if #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 32
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // ── AXI4-Lite read address channel ─────────────────────────────────
    input  wire [ADDR_WIDTH-1:0]         s_axi_araddr,
    input  wire                          s_axi_arvalid,
    output reg                           s_axi_arready,

    // ── AXI4-Lite read data channel ────────────────────────────────────
    output reg  [31:0]                   s_axi_rdata,
    output reg  [1:0]                    s_axi_rresp,
    output reg                           s_axi_rvalid,
    input  wire                          s_axi_rready,

    // ── Values to serve (from frame_input_if + track_ctrl) ─────────────
    input  wire [1:0]                    mode,
    input  wire signed [DATA_WIDTH-1:0]  thresh,
    input  wire signed [DATA_WIDTH-1:0]  kcf_thresh,
    input  wire signed [DATA_WIDTH-1:0]  lambda,
    input  wire                          stat_busy,
    input  wire                          stat_done,
    input  wire [1:0]                    stat_algo,
    input  wire                          stat_tracking,
    input  wire                          stat_found,
    input  wire [8:0]                    abs_row,
    input  wire [8:0]                    abs_col,
    input  wire signed [DATA_WIDTH-1:0]  confidence,
    input  wire                          irq_mask,
    input  wire                          irq_pending,
    input  wire [8:0]                    target_row,
    input  wire [8:0]                    target_col,
    input  wire [16:0]                   buf_idx
);

    // Register slots — addr[5:2]
    localparam REG_MODE       = 4'd1;    // 0x04
    localparam REG_THRESH     = 4'd2;    // 0x08
    localparam REG_LAMBDA     = 4'd3;    // 0x0C
    localparam REG_STATUS     = 4'd4;    // 0x10
    localparam REG_ABS_ROW    = 4'd5;    // 0x14
    localparam REG_ABS_COL    = 4'd6;    // 0x18
    localparam REG_CONFIDENCE = 4'd7;    // 0x1C
    localparam REG_IRQ_MASK   = 4'd8;    // 0x20
    localparam REG_IRQ_STAT   = 4'd9;    // 0x24
    localparam REG_TARGET_POS = 4'd11;   // 0x2C
    localparam REG_BUF_IDX    = 4'd12;   // 0x30
    localparam REG_KCF_THRESH = 4'd13;   // 0x34
    localparam REG_RESULT     = 4'd14;   // 0x38 — packed single-read result

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
        end else begin
            s_axi_arready <= 1'b0;

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;

            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;

                case (s_axi_araddr[5:2])

                    REG_MODE:
                        s_axi_rdata <= {30'd0, mode};

                    REG_THRESH:
                        s_axi_rdata <= {{(32-DATA_WIDTH){thresh[DATA_WIDTH-1]}},
                                         thresh};

                    REG_LAMBDA:
                        s_axi_rdata <= {{(32-DATA_WIDTH){lambda[DATA_WIDTH-1]}},
                                         lambda};

                    REG_STATUS:
                        s_axi_rdata <= {26'd0,
                                         stat_found,      // [5]
                                         stat_tracking,   // [4]
                                         stat_algo,       // [3:2]
                                         stat_done,       // [1]
                                         stat_busy};      // [0]

                    REG_ABS_ROW:
                        s_axi_rdata <= {23'd0, abs_row};

                    REG_ABS_COL:
                        s_axi_rdata <= {23'd0, abs_col};

                    REG_CONFIDENCE:
                        s_axi_rdata <= {{(32-DATA_WIDTH){confidence[DATA_WIDTH-1]}},
                                         confidence};

                    REG_IRQ_MASK:
                        s_axi_rdata <= {31'd0, irq_mask};

                    REG_IRQ_STAT:
                        s_axi_rdata <= {31'd0, irq_pending};

                    REG_TARGET_POS:
                        s_axi_rdata <= {7'd0, target_col, 7'd0, target_row};

                    REG_BUF_IDX:
                        s_axi_rdata <= {15'd0, buf_idx};

                    REG_KCF_THRESH:
                        s_axi_rdata <= {{(32-DATA_WIDTH){kcf_thresh[DATA_WIDTH-1]}},
                                         kcf_thresh};

                    // Packed single-read result — one AXI read gives the
                    // complete tracker state (understandable for NCC & KCF):
                    //   [31] found · [30] tracking · [29:28] algo (0=NCC,1=KCF)
                    //   [24:16] abs_row (0-239) · [8:0] abs_col (0-319)
                    REG_RESULT:
                        s_axi_rdata <= {stat_found, stat_tracking, stat_algo,
                                         3'd0, abs_row, 7'd0, abs_col};

                    // CTRL, IMAGE_FRAME (write-only) and reserved slots read 0
                    default:
                        s_axi_rdata <= 32'd0;

                endcase
            end
        end
    end

endmodule
