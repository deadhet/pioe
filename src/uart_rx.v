// =============================================================================
// uart_rx.v — PIOE UART receiver (8N1, LSB first, idle high)
// Spec: docs/specs/protocols/uart_rx.md  (final design §R.10)
//
// Edge + delay counting (PIO style):
//   falling edge -> wait ½ bit (glitch check, re-zero) -> sample every N clocks.
// Valid N: >= 8 (min), >= 16 recommended. N < 8 is undefined (§R.8a).
// =============================================================================
`default_nettype none

module uart_rx #(
    parameter CNT_W = 12,               // baud counter width
    parameter LAT   = 2                 // synchronizer delay, removed from ½-bit wait
) (
    input  wire             clk,
    input  wire             rst_n,          // active-low, synchronous
    input  wire [CNT_W-1:0] n,              // clocks per bit (N), from the program
    input  wire             rx,             // serial pin (asynchronous!)
    output reg  [7:0]       rx_data,        // last good byte (held)
    output reg              rx_valid,       // 1-clock pulse: rx_data updated
    output reg              rx_frame_err    // 1-clock pulse: stop bit was 0
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    // ---- Front end: 2-FF synchronizer ("airlock") + edge detector ----------
    // Reset to 1 (= idle line) so leaving reset can never look like an edge.
    reg rx_meta, rx_sync, rx_prev;
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            rx_prev <= 1'b1;
        end else begin
            rx_meta <= rx;          // FF1: may go metastable, has 1 clk to settle
            rx_sync <= rx_meta;     // FF2: clean copy - the ONLY one logic uses
            rx_prev <= rx_sync;     // FF3: last clock's value, for edge detect
        end
    end

    wire fall = rx_prev & ~rx_sync;     // was 1, now 0

    // ---- Timing ------------------------------------------------------------
    reg [1:0]       state;
    reg [CNT_W-1:0] baud_cnt;
    reg [2:0]       bit_cnt;
    reg [7:0]       rx_reg;             // collects bits (shift-in from the top)

    localparam [CNT_W-1:0] LAT_W = LAT;
    wire [CNT_W-1:0] half_cmp = (n >> 1) - 1'b1 - LAT_W;
    wire tick      = (baud_cnt == n - 1'b1);    // full bit-time over
    wire half_tick = (baud_cnt == half_cmp);    // ½ bit (latency-compensated)

    // ---- FSM: the per-clock flowchart in uart_rx.md §R.10 ------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            baud_cnt     <= {CNT_W{1'b0}};
            bit_cnt      <= 3'd0;
            rx_reg       <= 8'd0;
            rx_data      <= 8'd0;
            rx_valid     <= 1'b0;
            rx_frame_err <= 1'b0;
        end else begin
            rx_valid     <= 1'b0;       // default: pulses last one clock
            rx_frame_err <= 1'b0;

            case (state)
                // IDLE: counters parked, watch for the start-bit edge
                S_IDLE: begin
                    baud_cnt <= {CNT_W{1'b0}};
                    bit_cnt  <= 3'd0;
                    if (fall)
                        state <= S_START;
                end

                // START: at ½ bit, is the line still low?
                S_START: begin
                    if (half_tick) begin
                        if (!rx_sync) begin
                            baud_cnt <= {CNT_W{1'b0}};  // re-zero at mid start bit
                            state    <= S_DATA;
                        end else begin
                            state    <= S_IDLE;         // glitch - forget it
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                // DATA: every tick is the middle of a bit - sample it
                S_DATA: begin
                    if (tick) begin
                        rx_reg   <= {rx_sync, rx_reg[7:1]};  // enter at top
                        baud_cnt <= {CNT_W{1'b0}};
                        if (bit_cnt == 3'd7) begin
                            bit_cnt <= 3'd0;
                            state   <= S_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 3'd1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                // STOP: at mid stop bit, judge the frame and leave at once
                S_STOP: begin
                    if (tick) begin
                        baud_cnt <= {CNT_W{1'b0}};
                        state    <= S_IDLE;
                        if (rx_sync) begin
                            rx_data  <= rx_reg;
                            rx_valid <= 1'b1;
                        end else begin
                            rx_frame_err <= 1'b1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
