// =============================================================================
// uart_tx.v — PIOE UART transmitter (8N1, LSB first, idle high)
// Spec: docs/specs/protocols/uart_tx.md  (state diagram §T.4, flowchart §T.5)
//
// Frame: START(0) + 8 data bits (LSB first) + STOP(1), each held N clocks.
// One frame = exactly 10 * N clocks.
// =============================================================================
`default_nettype none

module uart_tx #(
    parameter CNT_W = 12                // baud counter width -> max N = 2^CNT_W - 1
) (
    input  wire             clk,
    input  wire             rst_n,      // active-low, synchronous
    input  wire [CNT_W-1:0] n,          // clocks per bit (N), from the program
    input  wire [7:0]       tx_data,    // byte to send
    input  wire             tx_start,   // "go" - only looked at in IDLE
    output reg              tx,         // serial pin (registered -> glitch-free)
    output wire             tx_busy,    // 1 while a frame is in flight
    output reg              tx_done     // 1-clock pulse when the frame ends
);

    // ---- State encoding (binary: 4 states -> 2 flip-flops) -----------------
    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]       state;
    reg [CNT_W-1:0] baud_cnt;   // stopwatch: 0 .. N-1, then wraps
    reg [2:0]       bit_cnt;    // which data bit: 0 .. 7
    reg [7:0]       tx_reg;     // private copy of the byte

    // tick = "one bit-time is over" (true for exactly one clock per bit)
    wire tick = (baud_cnt == n - 1'b1);

    assign tx_busy = (state != S_IDLE);

    // ---- One clocked block = the per-clock flowchart in uart_tx.md §T.5 ----
    // `tx` is assigned on the same edge that changes `state`, so the pin is
    // always a registered (Moore) output of the current state.
    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            baud_cnt <= {CNT_W{1'b0}};
            bit_cnt  <= 3'd0;
            tx_reg   <= 8'd0;
            tx       <= 1'b1;           // line idles high
            tx_done  <= 1'b0;
        end else begin
            tx_done <= 1'b0;            // default: pulse lasts one clock only

            case (state)
                // IDLE: line high, counters parked at 0, wait for tx_start
                S_IDLE: begin
                    tx       <= 1'b1;
                    baud_cnt <= {CNT_W{1'b0}};
                    bit_cnt  <= 3'd0;
                    if (tx_start) begin
                        tx_reg <= tx_data;      // latch once, on the arrow
                        tx     <= 1'b0;         // start bit begins now
                        state  <= S_START;
                    end
                end

                // START: hold 0 for one bit-time
                S_START: begin
                    if (tick) begin
                        baud_cnt <= {CNT_W{1'b0}};
                        tx       <= tx_reg[0];  // bit 0 goes out next
                        state    <= S_DATA;
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                // DATA: tx_reg[bit_cnt] on the pin, one bit-time each, x8
                S_DATA: begin
                    if (tick) begin
                        baud_cnt <= {CNT_W{1'b0}};
                        if (bit_cnt == 3'd7) begin
                            bit_cnt <= 3'd0;
                            tx      <= 1'b1;    // stop bit begins now
                            state   <= S_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 3'd1;
                            tx      <= tx_reg[bit_cnt + 3'd1];  // next bit
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                // STOP: hold 1 for one bit-time, then pulse tx_done
                S_STOP: begin
                    if (tick) begin
                        baud_cnt <= {CNT_W{1'b0}};
                        tx_done  <= 1'b1;
                        state    <= S_IDLE;
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
