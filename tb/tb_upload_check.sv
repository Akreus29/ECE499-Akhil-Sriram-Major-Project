`timescale 1ns/1ps
// tb_upload_check.sv — verifies the ICD v3 camera upload path in isolation:
// uploads one frame in camera order (RGB565, bottom-right first) and then
// backdoor-compares every stored frame word and every decimated pixel
// against TB-computed expectations.

module tb_upload_check;

    parameter FRAME_W = 320;
    parameter FRAME_H = 240;
    localparam FRAME_PIXELS = FRAME_W*FRAME_H;
    localparam FRAME_WORDS  = FRAME_PIXELS/2;
    localparam DEC_W = 80, DEC_H = 60;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg  [31:0] s_axi_awaddr = 0;  reg s_axi_awvalid = 0;  wire s_axi_awready;
    reg  [31:0] s_axi_wdata = 0;   reg [3:0] s_axi_wstrb = 4'hF;
    reg         s_axi_wvalid = 0;  wire s_axi_wready;
    wire [1:0]  s_axi_bresp;       wire s_axi_bvalid;  reg s_axi_bready = 1;
    reg  [31:0] s_axi_araddr = 0;  reg s_axi_arvalid = 0;  wire s_axi_arready;
    wire [31:0] s_axi_rdata;       wire [1:0] s_axi_rresp;
    wire        s_axi_rvalid;      reg s_axi_rready = 1;
    wire        irq_out;

    image_ip_axilite #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .irq_out(irq_out)
    );

    reg [15:0] img_rgb  [0:FRAME_PIXELS-1];
    reg [7:0]  img_gray [0:FRAME_PIXELS-1];

    function [7:0] luma;
        input [15:0] px;
        reg [7:0] r8, g8, b8;
        reg [15:0] acc;
        begin
            r8 = {px[15:11], px[15:13]};
            g8 = {px[10:5],  px[10:9]};
            b8 = {px[4:0],   px[4:2]};
            acc = 8'd77*r8 + 8'd150*g8 + 8'd29*b8;
            luma = acc[15:8];
        end
    endfunction

    task axi_write;
        input [31:0] addr; input [31:0] data;
        begin
            @(posedge clk); #1;
            s_axi_awaddr = addr; s_axi_awvalid = 1;
            s_axi_wdata  = data; s_axi_wvalid  = 1;
            fork
                begin while (!(s_axi_awvalid && s_axi_awready)) @(posedge clk); #1 s_axi_awvalid = 0; end
                begin while (!(s_axi_wvalid  && s_axi_wready))  @(posedge clk); #1 s_axi_wvalid  = 0; end
            join
            while (!s_axi_bvalid) @(posedge clk);
            @(posedge clk); #1;
        end
    endtask

    integer errors = 0;

    initial begin : main
        integer r, c, i, j, w, dr, dc, acc;
        reg [15:0] px_a, px_b, exp_word, got_word;
        reg [7:0]  exp_dec, got_dec;

        // Pattern with unique-ish values everywhere (diagonal gradient)
        for (r = 0; r < FRAME_H; r = r + 1)
            for (c = 0; c < FRAME_W; c = c + 1) begin
                i = r*FRAME_W + c;
                // spread bits across R/G/B so luma varies with position
                img_rgb[i]  = {r[4:0], c[5:0], r[6:2]};
                img_gray[i] = luma(img_rgb[i]);
            end

        rst_n = 0; #100; rst_n = 1; #100;

        // Camera-order upload
        axi_write(32'h30, 32'd0);
        for (j = 0; j < FRAME_WORDS; j = j + 1) begin
            px_a = img_rgb[FRAME_PIXELS-1 - 2*j];
            px_b = img_rgb[FRAME_PIXELS-2 - 2*j];
            axi_write(32'h28, {px_b[7:0], px_b[15:8], px_a[7:0], px_a[15:8]});
        end

        // 1. Frame buffer content check
        for (w = 0; w < FRAME_WORDS; w = w + 1) begin
            exp_word = {img_gray[2*w+1], img_gray[2*w]};
            got_word = dut.u_input.frame_buf[w];
            if (got_word !== exp_word && errors < 10) begin
                errors = errors + 1;
                $display("FRAME MISMATCH word %0d (px %0d,%0d): got %04x exp %04x",
                         w, 2*w, 2*w+1, got_word, exp_word);
            end
        end
        if (errors == 0) $display("Frame buffer: all %0d words exact.", FRAME_WORDS);

        // 2. Decimated buffer check (floor of 16-pixel mean)
        begin : dec_check
            integer dec_err;
            dec_err = 0;
            for (dr = 0; dr < DEC_H; dr = dr + 1)
                for (dc = 0; dc < DEC_W; dc = dc + 1) begin
                    acc = 0;
                    for (i = 0; i < 4; i = i + 1)
                        for (j = 0; j < 4; j = j + 1)
                            acc = acc + img_gray[(dr*4+i)*FRAME_W + (dc*4+j)];
                    exp_dec = acc / 16;
                    got_dec = dut.u_input.dec_buf[dr*DEC_W + dc];
                    if (got_dec !== exp_dec && dec_err < 10) begin
                        dec_err = dec_err + 1;
                        $display("DEC MISMATCH (%0d,%0d): got %0d exp %0d",
                                 dr, dc, got_dec, exp_dec);
                    end
                end
            if (dec_err == 0) $display("Decimated buffer: all %0d entries exact.",
                                       DEC_W*DEC_H);
            errors = errors + dec_err;
        end

        if (errors == 0) $display("tb_upload_check: ALL TESTS PASSED");
        else             $display("tb_upload_check: %0d MISMATCHES", errors);
        $finish;
    end

    initial begin #40_000_000; $display("TIMEOUT"); $finish; end

endmodule
