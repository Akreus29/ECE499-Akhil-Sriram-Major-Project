`timescale 1ns/1ps
// tb_kcf_debug.v — Debug testbench that traces intermediate values

module tb_kcf_debug;

    parameter N          = 32;
    parameter DATA_WIDTH = 16;
    parameter FRAC       = 8;
    parameter TOTAL      = N * N;

    reg  clk = 0, rst_n = 0, start = 0;
    reg  [$clog2(TOTAL)-1:0]       patch_addr;
    reg  signed [DATA_WIDTH-1:0]   patch_data;
    reg                            patch_wr_en;
    wire [$clog2(N)-1:0]           peak_row, peak_col;
    wire signed [DATA_WIDTH-1:0]   peak_val;
    wire                           done;

    always #5 clk = ~clk;

    kcf_detect_top #(.N(N), .DATA_WIDTH(DATA_WIDTH), .FRAC(FRAC)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .patch_addr(patch_addr), .patch_data(patch_data),
        .patch_wr_en(patch_wr_en),
        .peak_row(peak_row), .peak_col(peak_col), .peak_val(peak_val),
        .done(done)
    );

    reg signed [DATA_WIDTH-1:0] patch_mem [0:TOTAL-1];
    integer i;

    // Monitor state changes
    always @(dut.state) begin
        case (dut.state)
            4'd0: $display("T=%0t STATE: IDLE", $time);
            4'd1: $display("T=%0t STATE: HANN_WIN", $time);
            4'd2: $display("T=%0t STATE: FFT_LOAD", $time);
            4'd3: $display("T=%0t STATE: FFT_RUN", $time);
            4'd4: $display("T=%0t STATE: ELEM_MUL", $time);
            4'd5: $display("T=%0t STATE: IFFT_LOAD", $time);
            4'd6: $display("T=%0t STATE: IFFT_RUN", $time);
            4'd7: $display("T=%0t STATE: PEAK_RUN", $time);
            4'd8: $display("T=%0t STATE: DONE", $time);
        endcase
    end

    initial begin
        $readmemh("data/test_patch_32.mem", patch_mem);

        rst_n = 0; patch_wr_en = 0; start = 0;
        #20; rst_n = 1; #10;

        // Load patch
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            patch_addr  <= i;
            patch_data  <= patch_mem[i];
            patch_wr_en <= 1;
        end
        @(posedge clk);
        patch_wr_en <= 0;
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // Wait for HANN_WIN to finish
        wait(dut.state == 4'd2);  // FFT_LOAD
        @(posedge clk);
        // Print some windowed values
        $display("\nWindowed patch samples:");
        $display("  win[0]=%0d  win[1]=%0d  win[32]=%0d", dut.win_buf_re[0], dut.win_buf_re[1], dut.win_buf_re[32]);
        // The patch at (18,20) = index 18*32+20 = 596 should be the largest
        $display("  win[596]=%0d (feature location)", dut.win_buf_re[596]);

        // Wait for FFT to finish
        wait(dut.state == 4'd4);  // ELEM_MUL
        @(posedge clk);
        // Dump a few FFT output values
        $display("\nFFT output samples (via fft read port):");
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            // In ELEM_MUL, cnt drives fft_rd_addr. Let's just read directly.
        end

        // Wait for IFFT to finish
        wait(dut.state == 4'd7);  // PEAK_RUN
        @(posedge clk);

        // Wait for done
        @(posedge done);
        @(posedge clk);

        $display("\nPeak: row=%0d col=%0d val=%0d", peak_row, peak_col, peak_val);

        // Dump top-10 response map values
        $display("\nTop response values:");
        for (i = 0; i < TOTAL; i = i + 1) begin
            if ($signed(dut.resp_map[i]) > 20000)
                $display("  resp_map[%0d] (row=%0d,col=%0d) = %0d", i, i/N, i%N, dut.resp_map[i]);
        end

        #100;
        $finish;
    end

    initial begin
        #10_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
