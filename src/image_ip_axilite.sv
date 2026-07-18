`timescale 1ns/1ps
// =============================================================================
// image_ip_axilite.sv
// AXI4-Lite + AXI4-Stream wrapper for image_ip_top (NCC + KCF + handover)
//
// Instantiates image_ip_top and exposes a complete processor interface:
//   - AXI4-Lite slave  : register file (control, status, results)
//   - AXI4-Stream slave: patch / template pixel data from DMA
//   - irq_out          : maskable interrupt to PLIC on each detection result
//
// Intended for integration with the SHAKTI Yamuna RISC-V SoC (RV32IMACSU).
// Also compatible with any AXI4-Lite master (Zynq PS, MicroBlaze, etc.).
//
// ── AXI4-Lite Register Map (byte-addressed, 32-bit words) ─────────────────
//
//   Offset  Name        Dir    Bits       Description
//   ------  ----------  -----  ---------  -----------------------------------
//   0x00    CTRL        W      [0]        start     : pulse — begin detection
//                              [1]        sreset    : pulse — clear done flag
//                              [2]        tmpl_init : pulse — init NCC template
//                       (All bits are write-only and self-clearing)
//   0x04    MODE        R/W    [1:0]      0=AUTO, 1=NCC-only, 2=KCF-only
//   0x08    THRESH      R/W    [15:0]     NCC→KCF handover threshold (Q8.8 signed)
//   0x0C    LAMBDA      R/W    [15:0]     KCF regularisation λ  (Q8.8 signed)
//   0x10    STATUS      R      [0]        busy
//                              [1]        done  (latched; new start clears it)
//                              [3:2]      algo  00=NCC result, 01=KCF result
//                              [4]        stream_active
//   0x14    PEAK_ROW    R      [5:0]      row index of tracking peak  (0..N-1)
//   0x18    PEAK_COL    R      [5:0]      col index of tracking peak  (0..N-1)
//   0x1C    CONFIDENCE  R      [15:0]     confidence / score (Q8.8 signed, sx32)
//   0x20    IRQ_MASK    R/W    [0]        1 = assert irq_out when done
//   0x24    IRQ_STAT    R/W1C  [0]        1 = interrupt pending; write 1 to clear
//
// ── AXI4-Stream Protocol ──────────────────────────────────────────────────
//
//   TDATA  : 16-bit pixel (Q8.8 unsigned, 0..255 for raw 8-bit grayscale)
//   TUSER  : 0 = search patch, 1 = NCC template frame
//   TLAST  : asserted on the last pixel of each N×N frame
//   Pixel order: row-major, top-left first
//
// ── SHAKTI Software Sequence (AUTO mode) ──────────────────────────────────
//
//   1.  Write MODE   = 0x00000000   (AUTO)
//   2.  Write THRESH = 0x00000080   (Q8.8 = 0.5)
//   3.  Write LAMBDA = 0x00000001   (small regularisation)
//   4.  Write IRQ_MASK = 0x00000001 (enable interrupt)
//   5.  DMA  stream template pixels (TUSER=1, N×N beats)
//   6.  Write CTRL  = 0x00000004   (tmpl_init pulse)
//   --- tracking loop ---
//   7.  DMA  stream search patch (TUSER=0, N×N beats)
//   8.  Write CTRL  = 0x00000001   (start pulse)
//   9a. Wait for IRQ  OR
//   9b. Poll STATUS until bit[1]=1 (done)
//  10.  Read PEAK_ROW, PEAK_COL, CONFIDENCE, STATUS[3:2]
//  11.  Write IRQ_STAT = 0x00000001 (clear interrupt)
//  12.  Goto 7
//
// =============================================================================

module image_ip_axilite #(
    parameter N           = 64,     // patch / image dimension (N×N)
    parameter DATA_WIDTH  = 16,     // pixel / coefficient bit width
    parameter FRAC        = 8,      // fractional bits (Q(DW-FRAC).FRAC)
    parameter ADDR_WIDTH  = 32      // AXI address bus width
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ── AXI4-Stream slave (patch / template DMA) ──────────────────────────
    input  wire [DATA_WIDTH-1:0]    s_axis_tdata,
    input  wire                     s_axis_tvalid,
    output wire                     s_axis_tready,
    input  wire                     s_axis_tlast,
    input  wire                     s_axis_tuser,  // 0=patch, 1=template

    // ── AXI4-Lite slave — write address channel ────────────────────────────
    input  wire [ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire                     s_axi_awvalid,
    output reg                      s_axi_awready,

    // ── AXI4-Lite slave — write data channel ──────────────────────────────
    input  wire [31:0]              s_axi_wdata,
    input  wire [3:0]               s_axi_wstrb,
    input  wire                     s_axi_wvalid,
    output reg                      s_axi_wready,

    // ── AXI4-Lite slave — write response channel ───────────────────────────
    output reg  [1:0]               s_axi_bresp,
    output reg                      s_axi_bvalid,
    input  wire                     s_axi_bready,

    // ── AXI4-Lite slave — read address channel ─────────────────────────────
    input  wire [ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire                     s_axi_arvalid,
    output reg                      s_axi_arready,

    // ── AXI4-Lite slave — read data channel ───────────────────────────────
    output reg  [31:0]              s_axi_rdata,
    output reg  [1:0]               s_axi_rresp,
    output reg                      s_axi_rvalid,
    input  wire                     s_axi_rready,

    // ── Interrupt output (to PLIC / interrupt controller) ─────────────────
    output wire                     irq_out
);

    // =========================================================================
    //  Local parameters
    // =========================================================================
    localparam LOG2N = $clog2(N);   // 6 for N=64

    // Register offsets — bits [5:2] of byte address
    localparam REG_CTRL       = 4'd0;   // 0x00
    localparam REG_MODE       = 4'd1;   // 0x04
    localparam REG_THRESH     = 4'd2;   // 0x08
    localparam REG_LAMBDA     = 4'd3;   // 0x0C
    localparam REG_STATUS     = 4'd4;   // 0x10
    localparam REG_PEAK_ROW   = 4'd5;   // 0x14
    localparam REG_PEAK_COL   = 4'd6;   // 0x18
    localparam REG_CONFIDENCE = 4'd7;   // 0x1C
    localparam REG_IRQ_MASK   = 4'd8;   // 0x20
    localparam REG_IRQ_STAT   = 4'd9;   // 0x24

    // =========================================================================
    //  R/W control registers
    // =========================================================================
    reg [1:0]                   mode_reg;
    reg signed [DATA_WIDTH-1:0] thresh_reg;
    reg signed [DATA_WIDTH-1:0] lambda_reg;
    reg                         irq_mask_reg;

    // =========================================================================
    //  1-cycle control pulse registers
    //  Written by AXI write path; consumed combinationally by image_ip_top
    // =========================================================================
    reg  ctrl_start_r;
    reg  ctrl_sreset_r;
    reg  ctrl_tmpl_init_r;

    // =========================================================================
    //  Status / result captures from image_ip_top
    // =========================================================================
    wire                          ip_busy;
    wire                          ip_done;
    wire [1:0]                    ip_algo;
    wire                          ip_stream_active;
    wire [LOG2N-1:0]              ip_peak_row;
    wire [LOG2N-1:0]              ip_peak_col;
    wire signed [DATA_WIDTH-1:0]  ip_confidence;
    wire                          ip_irq_done;    // 1-cycle pulse on result ready

    // =========================================================================
    //  IRQ pending latch (W1C)
    //  Set/clear both handled inside the AXI write-path always block below
    //  (single driver). Set (ip_irq_done) takes priority over W1C clear.
    // =========================================================================
    reg  irq_pending;
    assign irq_out = irq_pending & irq_mask_reg;

    // =========================================================================
    //  image_ip_top instantiation
    // =========================================================================
    image_ip_top #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH),
        .FRAC       (FRAC)
    ) u_ip (
        .clk              (clk),
        .rst_n            (rst_n),

        // AXI4-Stream (patch / template)
        .s_axis_tdata     (s_axis_tdata),
        .s_axis_tvalid    (s_axis_tvalid),
        .s_axis_tready    (s_axis_tready),
        .s_axis_tlast     (s_axis_tlast),
        .s_axis_tuser     (s_axis_tuser),

        // Control inputs from register file
        .ctrl_mode        (mode_reg),
        .ctrl_start       (ctrl_start_r),
        .ctrl_soft_reset  (ctrl_sreset_r),
        .ctrl_tmpl_init   (ctrl_tmpl_init_r),
        .ctrl_thresh      (thresh_reg),
        .ctrl_lambda      (lambda_reg),

        // Status outputs to register file
        .stat_busy        (ip_busy),
        .stat_done        (ip_done),
        .stat_algo        (ip_algo),
        .stat_stream_active (ip_stream_active),
        .stat_peak_row    (ip_peak_row),
        .stat_peak_col    (ip_peak_col),
        .stat_confidence  (ip_confidence),
        .irq_done         (ip_irq_done)
    );

    // =========================================================================
    //  AXI4-Lite Write Path
    //
    //  Handles awvalid / wvalid arriving simultaneously or in either order.
    //  One outstanding write transaction at a time (single-issue).
    //
    //  State:
    //    aw_pend  — write address has been captured, waiting for write data
    //    w_pend   — write data arrived before address (captured, waiting)
    // =========================================================================
    reg [ADDR_WIDTH-1:0]  aw_addr_lat;
    reg                   aw_pend;      // address captured, waiting for data
    reg [31:0]            w_data_lat;
    reg                   w_pend;       // data captured, waiting for address

    // Self-clearing pulse signals — deasserted every cycle by default
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // AXI handshake
            s_axi_awready   <= 1'b0;
            s_axi_wready    <= 1'b0;
            s_axi_bvalid    <= 1'b0;
            s_axi_bresp     <= 2'b00;
            // Pending state
            aw_addr_lat     <= {ADDR_WIDTH{1'b0}};
            aw_pend         <= 1'b0;
            w_data_lat      <= 32'd0;
            w_pend          <= 1'b0;
            // R/W registers — safe power-on defaults
            mode_reg        <= 2'd0;            // AUTO
            thresh_reg      <= 16'sh0080;       // Q8.8 = 0.5
            lambda_reg      <= 16'sh0001;       // small λ
            irq_mask_reg    <= 1'b1;            // interrupt enabled by default
            // Pulse outputs
            ctrl_start_r    <= 1'b0;
            ctrl_sreset_r   <= 1'b0;
            ctrl_tmpl_init_r<= 1'b0;
            // IRQ
            irq_pending     <= 1'b0;
        end else begin

            // ── Default: deassert handshake strobes and control pulses ──────
            s_axi_awready    <= 1'b0;
            s_axi_wready     <= 1'b0;
            ctrl_start_r     <= 1'b0;
            ctrl_sreset_r    <= 1'b0;
            ctrl_tmpl_init_r <= 1'b0;

            // Release bvalid once master accepts the response
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            // ── Capture write address ───────────────────────────────────────
            if (s_axi_awvalid && !aw_pend && !s_axi_bvalid) begin
                aw_addr_lat  <= s_axi_awaddr;
                aw_pend      <= 1'b1;
                s_axi_awready<= 1'b1;
            end

            // ── Capture write data ──────────────────────────────────────────
            if (s_axi_wvalid && !w_pend && !s_axi_bvalid) begin
                w_data_lat   <= s_axi_wdata;
                w_pend       <= 1'b1;
                s_axi_wready <= 1'b1;
            end

            // ── Apply write once both address and data are available ────────
            if (aw_pend && w_pend && !s_axi_bvalid) begin
                aw_pend      <= 1'b0;
                w_pend       <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;   // OKAY

                case (aw_addr_lat[5:2])

                    REG_CTRL: begin
                        // Bits are write-only pulses; each generates a 1-cycle strobe
                        ctrl_start_r     <= w_data_lat[0];
                        ctrl_sreset_r    <= w_data_lat[1];
                        ctrl_tmpl_init_r <= w_data_lat[2];
                    end

                    REG_MODE:    mode_reg    <= w_data_lat[1:0];
                    REG_THRESH:  thresh_reg  <= w_data_lat[DATA_WIDTH-1:0];
                    REG_LAMBDA:  lambda_reg  <= w_data_lat[DATA_WIDTH-1:0];
                    REG_IRQ_MASK:irq_mask_reg<= w_data_lat[0];

                    REG_IRQ_STAT: begin
                        // W1C: writing 1 to bit[0] clears the pending flag
                        if (w_data_lat[0]) irq_pending <= 1'b0;
                    end

                    // STATUS, PEAK_*, CONFIDENCE are read-only — silently ignore writes
                    default: ;

                endcase
            end

            // ── IRQ pending: set on detection done (priority over W1C clear
            //    above, since this nonblocking assignment comes last) ────────
            if (ip_irq_done)
                irq_pending <= 1'b1;
        end
    end

    // =========================================================================
    //  AXI4-Lite Read Path
    //
    //  Zero-latency register reads: arready and rvalid asserted in the same
    //  cycle as arvalid.  rvalid held until master asserts rready.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
        end else begin
            s_axi_arready <= 1'b0;

            // Release rvalid once master accepts data
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;

            // Accept read address when not already presenting data
            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;

                case (s_axi_araddr[5:2])

                    REG_CTRL:   // CTRL is write-only; read returns 0
                        s_axi_rdata <= 32'd0;

                    REG_MODE:
                        s_axi_rdata <= {30'd0, mode_reg};

                    REG_THRESH:
                        s_axi_rdata <= {{(32-DATA_WIDTH){thresh_reg[DATA_WIDTH-1]}},
                                         thresh_reg};

                    REG_LAMBDA:
                        s_axi_rdata <= {{(32-DATA_WIDTH){lambda_reg[DATA_WIDTH-1]}},
                                         lambda_reg};

                    REG_STATUS:
                        s_axi_rdata <= {27'd0,
                                         ip_stream_active,   // [4]
                                         ip_algo,            // [3:2]
                                         ip_done,            // [1]
                                         ip_busy};           // [0]

                    REG_PEAK_ROW:
                        s_axi_rdata <= {{(32-LOG2N){1'b0}}, ip_peak_row};

                    REG_PEAK_COL:
                        s_axi_rdata <= {{(32-LOG2N){1'b0}}, ip_peak_col};

                    REG_CONFIDENCE:
                        s_axi_rdata <= {{(32-DATA_WIDTH){ip_confidence[DATA_WIDTH-1]}},
                                         ip_confidence};    // sign-extended

                    REG_IRQ_MASK:
                        s_axi_rdata <= {31'd0, irq_mask_reg};

                    REG_IRQ_STAT:
                        s_axi_rdata <= {31'd0, irq_pending};

                    default:
                        s_axi_rdata <= 32'd0;

                endcase
            end
        end
    end

endmodule
