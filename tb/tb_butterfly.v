`timescale 1ns/1ps
// tb_butterfly.v — testbench for butterfly.v

module tb_butterfly;

    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;

    reg  signed [DATA_WIDTH-1:0] in_re_a, in_im_a, in_re_b, in_im_b;
    reg  signed [DATA_WIDTH-1:0] w_re, w_im;
    wire signed [DATA_WIDTH-1:0] out_re_a, out_im_a, out_re_b, out_im_b;

    butterfly #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .in_re_a(in_re_a), .in_im_a(in_im_a),
        .in_re_b(in_re_b), .in_im_b(in_im_b),
        .w_re(w_re),        .w_im(w_im),
        .out_re_a(out_re_a), .out_im_a(out_im_a),
        .out_re_b(out_re_b), .out_im_b(out_im_b)
    );

    initial begin
        // Test 1: unity twiddle W=1+j0
        in_re_a = 16'h0100; in_im_a = 16'h0000;  // 1.0
        in_re_b = 16'h0100; in_im_b = 16'h0000;  // 1.0
        w_re    = 16'h0100; w_im    = 16'h0000;  // 1.0
        #10;
        $display("Test1 out_a=(%0d,%0d) out_b=(%0d,%0d)", out_re_a, out_im_a, out_re_b, out_im_b);
        // Expected: out_a = 2.0, out_b = 0.0

        // TODO: add more test vectors, compare against golden values
        $finish;
    end

endmodule
