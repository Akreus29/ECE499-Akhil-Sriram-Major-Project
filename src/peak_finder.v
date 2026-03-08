`timescale 1ns/1ps
// peak_finder.v
// Scans an N×N response map (real-valued after IFFT) and outputs the
// (row, col) coordinates of the maximum value — the predicted target location.
// Takes N*N clock cycles to complete the scan.

module peak_finder #(
    parameter N          = 32,
    parameter DATA_WIDTH = 16
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    input  wire signed [DATA_WIDTH-1:0]  response [0:N*N-1],  // row-major
    output reg  [$clog2(N)-1:0]          peak_row,
    output reg  [$clog2(N)-1:0]          peak_col,
    output reg  signed [DATA_WIDTH-1:0]  peak_val,
    output reg                           done
);

    localparam TOTAL = N * N;
    localparam ADDR_W = $clog2(TOTAL);

    localparam S_IDLE = 1'b0;
    localparam S_SCAN = 1'b1;

    reg        state;
    reg [ADDR_W-1:0] scan_addr;
    reg signed [DATA_WIDTH-1:0] cur_max;
    reg [$clog2(N)-1:0] max_row, max_col;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            scan_addr <= 0;
            cur_max   <= {1'b1, {(DATA_WIDTH-1){1'b0}}};  // most negative
            done      <= 0;
            peak_row  <= 0;
            peak_col  <= 0;
            peak_val  <= 0;
        end else begin
            done <= 0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        scan_addr <= 0;
                        cur_max   <= {1'b1, {(DATA_WIDTH-1){1'b0}}};
                        max_row   <= 0;
                        max_col   <= 0;
                        state     <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    // Compare current element against running maximum
                    if ($signed(response[scan_addr]) > $signed(cur_max)) begin
                        cur_max <= response[scan_addr];
                        max_row <= scan_addr / N;
                        max_col <= scan_addr % N;
                    end

                    if (scan_addr == TOTAL - 1) begin
                        // Scan complete — latch final result
                        // (if last element is the max, use it directly)
                        if ($signed(response[scan_addr]) > $signed(cur_max)) begin
                            peak_row <= scan_addr / N;
                            peak_col <= scan_addr % N;
                            peak_val <= response[scan_addr];
                        end else begin
                            peak_row <= max_row;
                            peak_col <= max_col;
                            peak_val <= cur_max;
                        end
                        done  <= 1;
                        state <= S_IDLE;
                    end else begin
                        scan_addr <= scan_addr + 1;
                    end
                end
            endcase
        end
    end

endmodule
