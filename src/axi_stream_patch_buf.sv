`timescale 1ns/1ps
// axi_stream_patch_buf.sv
// AXI4-Stream slave that receives a 64×64 patch (or template) and exposes
// the pixels via write-port outputs suitable for ncc_top / kcf_top.
//
// Packet structure (driven by DMA):
//   TUSER[0] = 0 → search patch
//   TUSER[0] = 1 → template initialisation
//   TLAST     = 1 on the last pixel of the packet (pixel index N*N - 1)
//
// When TLAST is received on a patch   packet: patch_ready  pulses for 1 cycle.
// When TLAST is received on a template packet: tmpl_ready pulses for 1 cycle.
//
// The wr_addr / wr_data / wr_en outputs fan out directly to:
//   ncc_top:  patch_addr/patch_data/patch_wr_en  AND  tmpl_wr_addr/data/en
//   kcf_top:  patch_addr/patch_data/patch_wr_en
// (all three trackers can share the same write-port signals; they have
//  independent storage so simultaneous writes are safe.)

module axi_stream_patch_buf #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // AXI4-Stream slave
    input  wire [DATA_WIDTH-1:0]      s_axis_tdata,
    input  wire                       s_axis_tvalid,
    output reg                        s_axis_tready,
    input  wire                       s_axis_tlast,
    input  wire                       s_axis_tuser,   // 0=patch, 1=template

    // Write-port to trackers — addr/data/en are registered TOGETHER so they
    // stay aligned (a combinational addr with a registered wr_en would write
    // the wrong pixel on the cycle after each handshake)
    output reg  [$clog2(N*N)-1:0]     wr_addr,
    output reg  signed [DATA_WIDTH-1:0] wr_data,
    output reg                        patch_wr_en,   // high when writing a patch pixel
    output reg                        tmpl_wr_en,    // high when writing a template pixel

    // Completion pulses
    output reg                        patch_ready,   // pulse: full patch received
    output reg                        tmpl_ready     // pulse: full template received
);

    localparam TOTAL    = N * N;   // 4096
    localparam ADDR_W   = $clog2(TOTAL);

    reg [ADDR_W-1:0] pixel_cnt;   // 0..TOTAL-1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axis_tready <= 1;    // always ready (no back-pressure needed)
            pixel_cnt     <= 0;
            wr_addr       <= 0;
            wr_data       <= 0;
            patch_wr_en   <= 0;
            tmpl_wr_en    <= 0;
            patch_ready   <= 0;
            tmpl_ready    <= 0;
        end else begin
            patch_wr_en <= 0;
            tmpl_wr_en  <= 0;
            patch_ready <= 0;
            tmpl_ready  <= 0;

            if (s_axis_tvalid && s_axis_tready) begin
                // Latch address and data with the enable — all three are
                // valid together on the following cycle
                wr_addr <= pixel_cnt;
                wr_data <= $signed(s_axis_tdata);
                if (s_axis_tuser) begin
                    // Template pixel
                    tmpl_wr_en <= 1;
                end else begin
                    // Patch pixel
                    patch_wr_en <= 1;
                end

                if (s_axis_tlast || pixel_cnt == TOTAL - 1) begin
                    // Last pixel in packet
                    if (s_axis_tuser)
                        tmpl_ready <= 1;
                    else
                        patch_ready <= 1;
                    pixel_cnt <= 0;
                end else begin
                    pixel_cnt <= pixel_cnt + 1;
                end
            end
        end
    end

endmodule
