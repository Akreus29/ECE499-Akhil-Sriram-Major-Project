`timescale 1ns/1ps
// kcf_top.v
// Top-level KCF tracker IP.
// Orchestrates detection and update phases via an FSM.
//
// Detection phase:
//   1. Apply Hann window to input patch
//   2. FFT2D(windowed patch)
//   3. Complex multiply FFT(patch) with stored alpha (conjugate)
//   4. IFFT2D → response map
//   5. Peak finder → (dy, dx) displacement
//
// Update phase (every frame or on keyframe):
//   1. FFT2D(windowed patch)
//   2. Gaussian kernel in freq domain
//   3. alpha = FFT(y) / (K_hat + lambda)
//   4. Store new alpha

module kcf_top #(
    parameter N          = 64,
    parameter DATA_WIDTH = 16,
    parameter FRAC       = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // AXI-Lite control interface (address map TBD)
    input  wire [31:0]                   s_axi_awaddr,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,
    input  wire [31:0]                   s_axi_wdata,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,
    output wire [1:0]                    s_axi_bresp,
    output wire                          s_axi_bvalid,
    input  wire                          s_axi_bready,
    input  wire [31:0]                   s_axi_araddr,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,
    output wire [31:0]                   s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output wire                          s_axi_rvalid,
    input  wire                          s_axi_rready,

    // Raw input patch (grayscale, row-major)
    input  wire [DATA_WIDTH-1:0]         patch_in [0:N*N-1],
    input  wire                          patch_valid,

    // Detected displacement output
    output reg  signed [$clog2(N):0]     disp_row,   // signed displacement
    output reg  signed [$clog2(N):0]     disp_col,
    output reg                           result_valid
);

    // TODO: FSM states: IDLE, INIT, DETECT, UPDATE, OUTPUT
    // TODO: instantiate fft2d_64, ifft2d_64, cmul, cconj_mul, cdiv,
    //        gauss_kernel, peak_finder, hann_rom, gauss_label_rom

endmodule
