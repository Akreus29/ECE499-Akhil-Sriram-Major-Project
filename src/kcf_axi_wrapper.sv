`timescale 1ns/1ps
// kcf_axi_wrapper.sv
//
// Wraps kcf_detect_top (N=32) with two AXI slave interfaces:
//   - AXI4-Stream slave  : receives 1024 × 16-bit pixels per 32×32 patch
//   - AXI4-Lite  slave  : control / status register file
//
// Intended for integration with the Shakti Yamuna RISC-V SoC on the
// same Artix-7 board.  The SoC DMA controller drives the AXI4-Stream
// port; the CPU core accesses registers via AXI4-Lite.
//
// ── AXI4-Lite register map (byte-addressed, 4-byte aligned) ──────────
//
//   Offset  Name           Access  Bits
//   0x00    CTRL           W/R     [0]  = start (self-clearing write)
//                                  [1]  = done  (latched, cleared on start)
//                                  [2]  = target_found (latched)
//   0x04    THRESHOLD      R/W     [15:0] conf_threshold (Q8.8, signed)
//   0x08    PEAK_ROW       R       [4:0]  row of response peak
//   0x0C    PEAK_COL       R       [4:0]  col of response peak
//   0x10    PEAK_VAL       R       [15:0] peak value (Q8.8, signed)
//   0x14    TARGET_FOUND   R       [0]    duplicate of CTRL[2]
//
// ── AXI4-Stream protocol ──────────────────────────────────────────────
//
//   - 16-bit TDATA; one pixel per beat; 1024 beats per patch (row-major)
//   - TLAST must be asserted on beat 1023
//   - TREADY is de-asserted while the wrapper is waiting for KCF to
//     finish the previous patch (backpressure)
//
// ── Expected SoC software sequence ───────────────────────────────────
//
//   1.  Write THRESHOLD (0x04) with conf_threshold value
//   2.  DMA: stream 1024 pixels via AXI4-Stream (TLAST on beat 1023)
//   3.  Write CTRL (0x00) bit[0] = 1  →  triggers KCF start
//   4.  Poll  CTRL (0x00) bit[1] until = 1  →  KCF done
//   5.  Read  PEAK_ROW / PEAK_COL / PEAK_VAL / TARGET_FOUND
//   6.  Repeat from step 2 for next patch

module kcf_axi_wrapper #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 32,
    parameter N          = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // ── AXI4-Stream slave ────────────────────────────────────────────────
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,          // informational; wrapper uses beat counter

    // ── AXI4-Lite slave — write address channel ──────────────────────────
    input  wire [ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire                   s_axi_awvalid,
    output reg                    s_axi_awready,

    // ── AXI4-Lite slave — write data channel ────────────────────────────
    input  wire [31:0]            s_axi_wdata,
    input  wire [3:0]             s_axi_wstrb,
    input  wire                   s_axi_wvalid,
    output reg                    s_axi_wready,

    // ── AXI4-Lite slave — write response channel ─────────────────────────
    output reg  [1:0]             s_axi_bresp,
    output reg                    s_axi_bvalid,
    input  wire                   s_axi_bready,

    // ── AXI4-Lite slave — read address channel ───────────────────────────
    input  wire [ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire                   s_axi_arvalid,
    output reg                    s_axi_arready,

    // ── AXI4-Lite slave — read data channel ─────────────────────────────
    output reg  [31:0]            s_axi_rdata,
    output reg  [1:0]             s_axi_rresp,
    output reg                    s_axi_rvalid,
    input  wire                   s_axi_rready
);

    localparam TOTAL = N * N;   // 1024

    // ════════════════════════════════════════════════════════════════════
    //  Signals to / from kcf_detect_top
    // ════════════════════════════════════════════════════════════════════
    reg                             start_pulse;
    reg  signed [DATA_WIDTH-1:0]    threshold_reg;

    // done_w is a 1-cycle pulse from kcf_detect_top (set in S_DONE only).
    // We latch it into done_latched so software can poll via AXI4-Lite.
    // target_found persists on its own (not in the default-zero list of kcf_detect_top).
    wire                            done_w;
    wire                            target_found_w;
    wire [$clog2(N)-1:0]            peak_row_w;
    wire [$clog2(N)-1:0]            peak_col_w;
    wire signed [DATA_WIDTH-1:0]    peak_val_w;

    reg                             done_latched;
    reg                             target_found_lat;

    // ════════════════════════════════════════════════════════════════════
    //  AXI4-Stream patch loader
    // ════════════════════════════════════════════════════════════════════
    //
    //  Two-state FSM:
    //    STREAM_LOADING — accepting beats (tready = 1)
    //    STREAM_IDLE    — waiting for the next KCF completion before
    //                     accepting a new patch (tready = 0, backpressure)
    //
    //  Transition IDLE → LOADING is gated on done_latched, ensuring the
    //  wrapper only opens tready after the previous detection finished and
    //  kcf_detect_top has returned to S_IDLE (where patch writes are accepted).

    localparam STREAM_LOADING = 1'b0;
    localparam STREAM_IDLE    = 1'b1;

    reg        stream_state;
    reg [9:0]  beat_cnt;        // 0 .. TOTAL-1

    // tready is combinational from stream_state
    assign s_axis_tready = (stream_state == STREAM_LOADING);

    // Patch memory write lines — combinational from the handshake
    wire                  patch_wr_en  = s_axis_tvalid & s_axis_tready;
    wire [9:0]            patch_addr   = beat_cnt;
    wire [DATA_WIDTH-1:0] patch_data   = s_axis_tdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_state <= STREAM_LOADING;  // ready to accept first patch immediately
            beat_cnt     <= 10'd0;
        end else begin
            case (stream_state)

                STREAM_LOADING: begin
                    if (patch_wr_en) begin
                        if (beat_cnt == TOTAL - 1) begin
                            // Last pixel received; wait for KCF to finish
                            beat_cnt     <= 10'd0;
                            stream_state <= STREAM_IDLE;
                        end else begin
                            beat_cnt <= beat_cnt + 10'd1;
                        end
                    end
                end

                STREAM_IDLE: begin
                    // Re-open once the previous KCF run has completed.
                    // done_latched is set by done_w (1-cycle pulse from kcf_detect_top)
                    // and cleared by start_pulse so it accurately tracks "new result ready".
                    if (done_latched)
                        stream_state <= STREAM_LOADING;
                end

                default: stream_state <= STREAM_LOADING;
            endcase
        end
    end

    // ════════════════════════════════════════════════════════════════════
    //  done / target_found latch
    // ════════════════════════════════════════════════════════════════════
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_latched     <= 1'b0;
            target_found_lat <= 1'b0;
        end else begin
            if (done_w) begin
                done_latched     <= 1'b1;
                target_found_lat <= target_found_w;
            end else if (start_pulse) begin
                done_latched <= 1'b0;
                // keep target_found_lat from previous run until new result
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════
    //  AXI4-Lite write path
    // ════════════════════════════════════════════════════════════════════
    //
    //  Simplified single-outstanding-transaction implementation:
    //    awaddr is latched when awvalid is seen (aw_addr_valid flag).
    //    Write data is applied once both aw_addr_valid and wvalid are true.
    //    awvalid and wvalid may arrive simultaneously or in either order.

    reg [ADDR_WIDTH-1:0] aw_addr_lat;
    reg                  aw_addr_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_addr_lat   <= {ADDR_WIDTH{1'b0}};
            aw_addr_valid <= 1'b0;
            threshold_reg <= {DATA_WIDTH{1'b0}};
            start_pulse   <= 1'b0;
        end else begin
            // Defaults — deassert handshake strobes every cycle
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            start_pulse   <= 1'b0;

            // Release bvalid once master accepts the response
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            // Capture write address (one outstanding address at a time)
            if (s_axi_awvalid && !aw_addr_valid) begin
                aw_addr_lat   <= s_axi_awaddr;
                aw_addr_valid <= 1'b1;
                s_axi_awready <= 1'b1;
            end

            // Apply write data once address is captured and response channel is free
            if (s_axi_wvalid && aw_addr_valid && !s_axi_bvalid) begin
                s_axi_wready  <= 1'b1;
                aw_addr_valid <= 1'b0;
                s_axi_bvalid  <= 1'b1;
                s_axi_bresp   <= 2'b00;   // OKAY

                // Register decode — word-addressed via bits [4:2]
                case (aw_addr_lat[4:2])
                    3'd0: begin   // CTRL — bit[0] issues a 1-cycle start pulse
                        if (s_axi_wdata[0])
                            start_pulse <= 1'b1;
                    end
                    3'd1: begin   // THRESHOLD
                        threshold_reg <= s_axi_wdata[DATA_WIDTH-1:0];
                    end
                    default: ;    // PEAK_* are read-only; silently ignore writes
                endcase
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════
    //  AXI4-Lite read path
    // ════════════════════════════════════════════════════════════════════
    //
    //  Single-cycle address acceptance: arready and rvalid asserted in the
    //  same clock as arvalid (zero-latency data); rvalid held until rready.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
        end else begin
            s_axi_arready <= 1'b0;

            // Release rvalid once master accepts the data
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;

            // Accept new read address when not already presenting read data
            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;

                case (s_axi_araddr[4:2])
                    3'd0: s_axi_rdata <= {29'd0,
                                          target_found_lat,
                                          done_latched,
                                          1'b0};
                    3'd1: s_axi_rdata <= {{(32-DATA_WIDTH){1'b0}},
                                          threshold_reg};
                    3'd2: s_axi_rdata <= {{(32-$clog2(N)){1'b0}},
                                          peak_row_w};
                    3'd3: s_axi_rdata <= {{(32-$clog2(N)){1'b0}},
                                          peak_col_w};
                    3'd4: s_axi_rdata <= {{(32-DATA_WIDTH){peak_val_w[DATA_WIDTH-1]}},
                                          peak_val_w};   // sign-extended
                    3'd5: s_axi_rdata <= {31'd0, target_found_lat};
                    default: s_axi_rdata <= 32'd0;
                endcase
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════
    //  kcf_detect_top instantiation (N=32, unchanged)
    // ════════════════════════════════════════════════════════════════════
    kcf_detect_top #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH),
        .FRAC       (8)
    ) u_kcf (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start_pulse),
        .patch_addr     (patch_addr),
        .patch_data     (patch_data),
        .patch_wr_en    (patch_wr_en),
        .conf_threshold (threshold_reg),
        .peak_row       (peak_row_w),
        .peak_col       (peak_col_w),
        .peak_val       (peak_val_w),
        .target_found   (target_found_w),
        .done           (done_w)
    );

endmodule
