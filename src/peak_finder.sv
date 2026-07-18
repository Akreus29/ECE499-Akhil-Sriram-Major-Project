`timescale 1ns/1ps
// peak_finder.sv
// Scans an N×N response map (real-valued after IFFT) and outputs the
// (row, col) coordinates of the maximum value — the predicted target location.
//
// SYNTHESIZABLE VERSION: instead of taking the whole response map as an
// unpacked-array port (which pins the caller's buffer into LUT fabric),
// the module is a read master on a synchronous single-port memory:
//
//   - drives  rd_addr  (to the caller's resp_map BRAM read port)
//   - samples rd_data  exactly 1 cycle after the address was presented
//
// Scan takes N*N + 2 clock cycles.  row/col are recovered from the delayed
// address by bit-slicing (N is a power of two), so no divide/modulo logic.

module peak_finder #(
    parameter N          = 32,
    parameter DATA_WIDTH = 16
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,

    // Read-master interface to the caller's response-map BRAM
    output reg  [$clog2(N*N)-1:0]        rd_addr,
    input  wire signed [DATA_WIDTH-1:0]  rd_data,   // valid 1 cycle after rd_addr

    output reg  [$clog2(N)-1:0]          peak_row,
    output reg  [$clog2(N)-1:0]          peak_col,
    output reg  signed [DATA_WIDTH-1:0]  peak_val,
    output reg                           done
);

    localparam TOTAL  = N * N;
    localparam ADDR_W = $clog2(TOTAL);
    localparam LOG2N  = $clog2(N);

    localparam S_IDLE = 1'b0;
    localparam S_SCAN = 1'b1;

    reg                  state;
    reg [ADDR_W-1:0]     addr_d;       // address the current rd_data belongs to
    reg                  data_valid;   // rd_data corresponds to addr_d this cycle
    reg                  last_seen;    // addr_d == TOTAL-1 data has been compared
    reg signed [DATA_WIDTH-1:0] cur_max;
    reg [LOG2N-1:0]      max_row, max_col;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            rd_addr    <= {ADDR_W{1'b0}};
            addr_d     <= {ADDR_W{1'b0}};
            data_valid <= 1'b0;
            last_seen  <= 1'b0;
            cur_max    <= {1'b1, {(DATA_WIDTH-1){1'b0}}};  // most negative
            max_row    <= {LOG2N{1'b0}};
            max_col    <= {LOG2N{1'b0}};
            done       <= 1'b0;
            peak_row   <= {LOG2N{1'b0}};
            peak_col   <= {LOG2N{1'b0}};
            peak_val   <= {DATA_WIDTH{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)

                S_IDLE: begin
                    data_valid <= 1'b0;
                    if (start) begin
                        rd_addr    <= {ADDR_W{1'b0}};
                        addr_d     <= {ADDR_W{1'b0}};
                        last_seen  <= 1'b0;
                        cur_max    <= {1'b1, {(DATA_WIDTH-1){1'b0}}};
                        max_row    <= {LOG2N{1'b0}};
                        max_col    <= {LOG2N{1'b0}};
                        state      <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    // Address pipeline: rd_data this cycle belongs to addr_d
                    addr_d     <= rd_addr;
                    data_valid <= 1'b1;
                    if (rd_addr != TOTAL - 1)
                        rd_addr <= rd_addr + 1'b1;

                    // Compare the arriving element against the running max
                    if (data_valid) begin
                        if ($signed(rd_data) > $signed(cur_max)) begin
                            cur_max <= rd_data;
                            max_row <= addr_d[ADDR_W-1:LOG2N];   // addr / N
                            max_col <= addr_d[LOG2N-1:0];        // addr % N
                        end

                        if (addr_d == TOTAL - 1) begin
                            // Final element compared — latch the result
                            if ($signed(rd_data) > $signed(cur_max)) begin
                                peak_row <= addr_d[ADDR_W-1:LOG2N];
                                peak_col <= addr_d[LOG2N-1:0];
                                peak_val <= rd_data;
                            end else begin
                                peak_row <= max_row;
                                peak_col <= max_col;
                                peak_val <= cur_max;
                            end
                            done       <= 1'b1;
                            data_valid <= 1'b0;
                            state      <= S_IDLE;
                        end
                    end
                end

            endcase
        end
    end

endmodule
