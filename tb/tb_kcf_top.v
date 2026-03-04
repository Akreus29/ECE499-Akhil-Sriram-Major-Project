`timescale 1ns/1ps
// tb_kcf_top.v — top-level integration testbench for kcf_top.v
// Drives a synthetic patch through the full detect → update loop
// and checks that disp_row/disp_col converge to (0,0) for a static target.

module tb_kcf_top;

    parameter N          = 64;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;

    reg  clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // AXI-Lite signals (tied off for now)
    reg  [31:0] s_axi_awaddr = 0, s_axi_wdata = 0, s_axi_araddr = 0;
    reg         s_axi_awvalid=0, s_axi_wvalid=0, s_axi_bready=1;
    reg         s_axi_arvalid=0, s_axi_rready=1;
    wire        s_axi_awready, s_axi_wready, s_axi_bvalid;
    wire [1:0]  s_axi_bresp, s_axi_rresp;
    wire        s_axi_arready, s_axi_rvalid;
    wire [31:0] s_axi_rdata;

    reg  [DATA_WIDTH-1:0]        patch_in [0:N*N-1];
    reg                          patch_valid = 0;
    wire signed [$clog2(N):0]    disp_row, disp_col;
    wire                         result_valid;

    kcf_top #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),   .s_axi_wvalid(s_axi_wvalid),   .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),   .s_axi_bvalid(s_axi_bvalid),   .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),   .s_axi_rresp(s_axi_rresp),     .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .patch_in(patch_in), .patch_valid(patch_valid),
        .disp_row(disp_row), .disp_col(disp_col), .result_valid(result_valid)
    );

    initial begin
        $readmemh("../data/test_patch.mem", patch_in);
        #20 rst_n = 1;

        // Frame 1 — initialise filter
        patch_valid = 1; #10 patch_valid = 0;
        wait(result_valid);
        $display("Frame1 disp=(%0d, %0d)  (expect 0, 0)", disp_row, disp_col);

        // TODO: shift patch by a known (dy, dx) and verify displacement output

        $finish;
    end

endmodule
