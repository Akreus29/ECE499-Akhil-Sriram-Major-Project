`timescale 1ns/1ps
// tb_fft1d_32.v
// Unit testbench for fft1d_32.v (32-point 1D FFT)
// Test 1: DC impulse — in[0]=1/32, rest=0 → all outputs ≈ 1/32 (scaled FFT)
// Test 2: All-ones  — every in[n]=1/32 → out[0] = 1/32, rest ≈ 0

module tb_fft1d_32;

    parameter N          = 32;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;

    reg  clk = 0, rst_n = 0, start = 0;
    reg  signed [DATA_WIDTH-1:0] in_re [0:N-1];
    reg  signed [DATA_WIDTH-1:0] in_im [0:N-1];
    wire signed [DATA_WIDTH-1:0] out_re [0:N-1];
    wire signed [DATA_WIDTH-1:0] out_im [0:N-1];
    wire done;

    always #5 clk = ~clk;

    fft1d_32 #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .in_re(in_re), .in_im(in_im),
        .out_re(out_re), .out_im(out_im),
        .done(done)
    );

    integer i;
    integer errors;

    initial begin
        $dumpfile("fft1d_32.vcd");
        $dumpvars(0, tb_fft1d_32);

        // ── Test 1: DC impulse ──────────────────────────────────────
        // Input: x[0] = 0.125 (0x0020 in Q8.8), x[1..31] = 0
        // After 5 butterfly stages with >>>1 scaling, the DC input
        // gets divided by 2^5 = 32 total. So input of 0.125 should
        // give output ≈ 0.125/32 ≈ 0.004 for all bins.
        // Let's use a larger value: x[0] = 1.0 (0x0100)
        // Expected: each output ≈ 1.0 / 32 = 0.03125 (0x0008)
        $display("\n══ Test 1: DC impulse ══");
        for (i = 0; i < N; i = i + 1) begin
            in_re[i] = (i == 0) ? 16'sh0100 : 16'sh0000;
            in_im[i] = 16'sh0000;
        end

        rst_n = 0; #20; rst_n = 1; #10;
        @(posedge clk); start <= 1;
        @(posedge clk); start <= 0;

        @(posedge done);
        @(posedge clk);

        errors = 0;
        for (i = 0; i < N; i = i + 1) begin
            // With scaled FFT (>>>1 each stage), DC impulse should give
            // roughly 1/32 = 0x0008 for real, 0 for imag at each bin
            if (out_im[i] != 0) begin
                $display("  Bin %2d: re=%6d im=%6d  [imag non-zero!]", i, out_re[i], out_im[i]);
                errors = errors + 1;
            end
        end
        $display("  Bin[0] = re=%0d (expect ~8), im=%0d (expect 0)", out_re[0], out_im[0]);
        $display("  Bin[1] = re=%0d (expect ~8), im=%0d (expect 0)", out_re[1], out_im[1]);
        if (errors == 0)
            $display("  PASS: All imaginary parts are zero.");
        else
            $display("  %0d bins had non-zero imag (may be truncation noise).", errors);

        // ── Test 2: All ones ────────────────────────────────────────
        // Input: all x[n] = 0.25 (0x0040)
        // FFT of constant = N*const at bin 0, zero elsewhere.
        // With scaled FFT: bin[0] = 0.25 (no growth since add+shift cancels)
        // Other bins: should be zero
        $display("\n══ Test 2: All ones ══");
        for (i = 0; i < N; i = i + 1) begin
            in_re[i] = 16'sh0040;  // 0.25 in Q8.8
            in_im[i] = 16'sh0000;
        end

        @(posedge clk); start <= 1;
        @(posedge clk); start <= 0;

        @(posedge done);
        @(posedge clk);

        $display("  Bin[0] = re=%0d im=%0d", out_re[0], out_im[0]);
        $display("  Bin[1] = re=%0d im=%0d (expect ~0)", out_re[1], out_im[1]);
        $display("  Bin[16] = re=%0d im=%0d (expect ~0)", out_re[16], out_im[16]);

        #100;
        $display("\nAll tests complete.");
        $finish;
    end

endmodule
