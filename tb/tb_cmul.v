`timescale 1ns/1ps
// tb_cmul.v — testbench for cmul.v and cconj_mul.v

module tb_cmul;

    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;

    reg  signed [DATA_WIDTH-1:0] a_re, a_im, b_re, b_im;
    wire signed [DATA_WIDTH-1:0] mul_re,  mul_im;
    wire signed [DATA_WIDTH-1:0] conj_re, conj_im;

    cmul #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cmul (
        .a_re(a_re), .a_im(a_im),
        .b_re(b_re), .b_im(b_im),
        .out_re(mul_re), .out_im(mul_im)
    );

    cconj_mul #(.DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) u_cconj (
        .a_re(a_re), .a_im(a_im),
        .b_re(b_re), .b_im(b_im),
        .out_re(conj_re), .out_im(conj_im)
    );

    initial begin
        // (1+j1) * (1+j1) = 0+j2
        a_re = 16'h0100; a_im = 16'h0100;
        b_re = 16'h0100; b_im = 16'h0100;
        #10;
        $display("cmul:      re=%0d im=%0d  (expect 0, 512)", mul_re,  mul_im);
        $display("cconj_mul: re=%0d im=%0d  (expect 512, 0)", conj_re, conj_im);

        // TODO: edge cases, negative values, saturation
        $finish;
    end

endmodule
