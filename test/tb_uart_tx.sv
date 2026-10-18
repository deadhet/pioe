// =============================================================================
// tb_uart_tx.sv — tests the PIOE UART TRANSMITTER (uart_tx) on its own
//
// Two independent judges watch the tx pin:
//   1. PIN CHECKER (this file): knows what every clock of the frame must look
//      like, and checks the pin on EVERY clock (bit values and exact timing).
//   2. REFERENCE RECEIVER (ref_uart_rx, third-party, test/ref/): a real UART
//      receiver. If it decodes the same byte, our frame is a real UART frame.
//      It needs N = multiple of 8, so for other N only the pin checker is used.
//
// Also tested: inputs changing while TX is busy (in every state), reset in
// every state, reset + start together, and X / Z on the inputs.
//
// Coverage: every byte value, every N group, every FSM state and transition,
// every "input poked while busy" case, and every test scenario.
// =============================================================================
`timescale 1ns/1ps

module tb_uart_tx;

    // -------------------------------------------------------------------------
    // Clock: 20 MHz (50 ns period), the example clock in the spec
    // -------------------------------------------------------------------------
    localparam real CLOCK_PERIOD = 50.0;

    logic clk = 0;
    always #(CLOCK_PERIOD / 2) clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT: our transmitter
    // -------------------------------------------------------------------------
    logic        rst_n    = 0;      // active-low reset
    logic [11:0] n        = 16;     // clocks per bit
    logic [7:0]  tx_data  = 0;
    logic        tx_start = 0;
    wire         tx;
    wire         tx_busy;
    wire         tx_done;

    uart_tx dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .n        (n),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx       (tx),
        .tx_busy  (tx_busy),
        .tx_done  (tx_done)
    );

    // FSM state names (same numbers as inside uart_tx.v)
    localparam IDLE  = 0;
    localparam START = 1;
    localparam DATA  = 2;
    localparam STOP  = 3;

    // -------------------------------------------------------------------------
    // Reference receiver (third-party). Its bit time is prescale * 8 clocks.
    // -------------------------------------------------------------------------
    wire [7:0]  ref_data;
    wire        ref_valid;
    wire        ref_busy;
    wire        ref_overrun;
    wire        ref_frame_error;
    wire [15:0] ref_prescale = n / 8;

    ref_uart_rx ref_rx (
        .clk           (clk),
        .rst           (!rst_n),        // it uses active-high reset
        .m_axis_tdata  (ref_data),
        .m_axis_tvalid (ref_valid),
        .m_axis_tready (1'b1),          // always ready to take a byte
        .rxd           (tx),            // it listens to OUR tx pin
        .busy          (ref_busy),
        .overrun_error (ref_overrun),
        .frame_error   (ref_frame_error),
        .prescale      (ref_prescale)
    );

    // What the reference receiver has seen
    int         ref_byte_count  = 0;
    int         ref_error_count = 0;
    logic [7:0] ref_last_byte   = 0;

    always @(negedge clk) begin
        if (ref_valid) begin
            ref_byte_count = ref_byte_count + 1;
            ref_last_byte  = ref_data;
        end
        if (ref_frame_error)
            ref_error_count = ref_error_count + 1;
    end

    // -------------------------------------------------------------------------
    // Pass / fail bookkeeping
    // -------------------------------------------------------------------------
    int error_count = 0;
    int check_count = 0;
    int frame_count = 0;

    function void check(input bit condition_ok, input string message);
        check_count = check_count + 1;
        if (!condition_ok) begin
            error_count = error_count + 1;
            $display("ERROR at %t: %s", $realtime, message);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Always-on checks (every clock, after reset)
    // -------------------------------------------------------------------------
    bit   pin_may_be_unknown = 0;   // only set in the "X on tx_data" test
    logic tx_done_last_clock = 0;

    always @(negedge clk) begin
        if (rst_n) begin
            // Control outputs and the FSM state must never be X or Z
            if ($isunknown(tx_busy) || $isunknown(tx_done) || $isunknown(dut.state))
                check(0, "tx_busy / tx_done / state is X or Z");
            if (!pin_may_be_unknown && $isunknown(tx))
                check(0, "tx pin is X or Z");
            // tx_done must be a 1-clock pulse
            if (tx_done && tx_done_last_clock)
                check(0, "tx_done stayed high for more than 1 clock");
            // Line must be high whenever TX is idle
            if (!tx_busy && tx !== 1'b1 && !pin_may_be_unknown)
                check(0, "tx is not high while idle");
        end
        tx_done_last_clock = tx_done;
    end

    // -------------------------------------------------------------------------
    // Functional coverage
    // -------------------------------------------------------------------------
    logic [7:0] byte_sent;      // the byte of the frame just checked

    covergroup frame_coverage;
        byte_value: coverpoint byte_sent {
            bins value[] = {[0:255]};               // all 256 byte values
        }
        byte_range: coverpoint byte_sent {
            bins low      = {[0:63]};
            bins mid_low  = {[64:127]};
            bins mid_high = {[128:191]};
            bins high     = {[192:255]};
        }
        clocks_per_bit: coverpoint n {
            bins n8    = {8};       // N_min
            bins n9    = {9};       // odd
            bins n16   = {16};      // recommended
            bins n17   = {17};      // odd
            bins n24   = {24};
            bins n174  = {174};     // 115200 baud at 20 MHz
            bins n175  = {175};     // odd
            bins n176  = {176};
            bins n4088 = {4088};    // largest multiple of 8
            bins n4095 = {4095};    // max for 12 bits
        }
        range_and_n: cross byte_range, clocks_per_bit;
    endgroup

    // FSM: every state and every transition (sampled every clock)
    covergroup state_coverage @(posedge clk);
        state: coverpoint dut.state {
            bins idle  = {IDLE};
            bins start = {START};
            bins data  = {DATA};
            bins stop  = {STOP};
            bins idle_to_start = (IDLE  => START);
            bins start_to_data = (START => DATA);
            bins data_to_stop  = (DATA  => STOP);
            bins stop_to_idle  = (STOP  => IDLE);
            bins reset_in_start = (START => IDLE);  // only reset can do this
            bins reset_in_data  = (DATA  => IDLE);  // only reset can do this
        }
    endgroup

    // Inputs changed WHILE the transmitter is busy (simultaneous inputs)
    typedef enum {POKE_START, POKE_DATA, POKE_START_AND_DATA, POKE_RESET} poke_type_t;
    poke_type_t poke_type;
    logic [1:0] state_when_poked;

    covergroup poke_coverage;
        state_poked: coverpoint state_when_poked {
            bins start = {START};
            bins data  = {DATA};
            bins stop  = {STOP};
        }
        what_poked: coverpoint poke_type;
        state_and_poke: cross state_poked, what_poked;
    endgroup

    // Every test scenario ran at least once
    typedef enum {
        RESET_VALUES, RESET_AND_START_TOGETHER, BACK_TO_BACK, START_ON_LAST_STOP_CLOCK,
        N_CHANGED, START_IS_X, START_IS_Z, DATA_HAS_X_AND_Z
    } scenario_t;
    scenario_t scenario;

    covergroup scenario_coverage;
        which: coverpoint scenario;
    endgroup

    frame_coverage    frame_cov    = new();
    state_coverage    state_cov    = new();
    poke_coverage     poke_cov     = new();
    scenario_coverage scenario_cov = new();

    function void scenario_done(input scenario_t s);
        scenario = s;
        scenario_cov.sample();
    endfunction

    // -------------------------------------------------------------------------
    // Helper tasks
    // -------------------------------------------------------------------------
    // The TB changes inputs on the FALLING edge and reads outputs on the
    // falling edge. The DUT works on the RISING edge, so they never race.

    // "automatic" = each call gets its own copy of how_many, so two copies
    // can run at the same time inside a fork
    task automatic wait_clocks(input int how_many);
        repeat (how_many) @(negedge clk);
    endtask

    task wait_until_idle();
        @(negedge clk);
        while (tx_busy) @(negedge clk);
    endtask

    task reset_dut();
        @(negedge clk);
        rst_n    = 0;
        tx_start = 0;
        wait_clocks(4);
        ref_byte_count  = 0;
        ref_error_count = 0;
        rst_n = 1;
        wait_clocks(2);
    endtask

    task set_clocks_per_bit(input int new_n);
        wait_until_idle();
        n = new_n;
    endtask

    // Pin checker. Call it on the falling edge right after the start was
    // accepted (the start bit has just begun). It walks through the 10 bits,
    // N clocks each, and checks the tx pin on EVERY clock.
    task check_frame_on_pin(input logic [7:0] expected_byte);
        logic expected_bit;
        bit   frame_ok;
        frame_ok = 1;

        for (int bit_number = 0; bit_number < 10; bit_number++) begin
            if (bit_number == 0)
                expected_bit = 1'b0;                        // start bit
            else if (bit_number == 9)
                expected_bit = 1'b1;                        // stop bit
            else
                expected_bit = expected_byte[bit_number - 1]; // data, LSB first

            for (int clock_number = 0; clock_number < n; clock_number++) begin
                if (frame_ok && tx !== expected_bit) begin
                    check(0, $sformatf("byte %h, bit %0d, clock %0d of %0d: tx = %b, expected %b",
                                       expected_byte, bit_number, clock_number, n, tx, expected_bit));
                    frame_ok = 0;
                end
                if (frame_ok && tx_busy !== 1'b1) begin
                    check(0, "tx_busy went low in the middle of a frame");
                    frame_ok = 0;
                end
                if (frame_ok && tx_done !== 1'b0) begin
                    check(0, "tx_done came before the frame ended");
                    frame_ok = 0;
                end
                @(negedge clk);
            end
        end

        // Exactly 10 * N clocks later the frame must be over
        check(frame_ok, $sformatf("frame %h checked clock by clock", expected_byte));
        check(tx_done === 1'b1, "tx_done pulse right after the stop bit (10*N clocks)");
        check(tx_busy === 1'b0, "tx_busy low after the frame");
        check(tx      === 1'b1, "line high after the frame");

        byte_sent   = expected_byte;
        frame_count = frame_count + 1;
        if (!$isunknown(expected_byte)) frame_cov.sample();
    endtask

    // The reference receiver must have decoded exactly this one byte
    task check_reference_got(input logic [7:0] expected_byte, input int bytes_before);
        if (n % 8 == 0) begin
            wait_clocks(2);
            check(ref_byte_count == bytes_before + 1 && ref_last_byte === expected_byte,
                  $sformatf("reference RX decoded %h (count %0d), expected %h",
                            ref_last_byte, ref_byte_count - bytes_before, expected_byte));
            check(ref_error_count == 0, "reference RX saw a frame error");
        end
    endtask

    // Send one byte: a 1-clock tx_start pulse, then check the whole frame
    task send_byte(input logic [7:0] byte_to_send);
        int bytes_before;
        wait_until_idle();
        bytes_before = ref_byte_count;
        tx_data  = byte_to_send;
        tx_start = 1;
        @(negedge clk);             // the DUT accepted it on the rising edge
        tx_start = 0;
        check_frame_on_pin(byte_to_send);
        check_reference_got(byte_to_send, bytes_before);
    endtask

    // Line must stay idle (no new frame) for a while
    task check_stays_idle(input int how_many_clocks, input string message);
        bit stayed_idle;
        stayed_idle = 1;
        repeat (how_many_clocks) begin
            @(negedge clk);
            if (tx_busy !== 1'b0 || tx !== 1'b1) stayed_idle = 0;
        end
        check(stayed_idle, message);
    endtask

    // =========================================================================
    // TESTS
    // =========================================================================

    // 1. Reset values, and nothing happens after reset is released
    task automatic test_reset_values();
        $display("--- 1. reset values   [t = %t]", $realtime);
        rst_n = 0;
        wait_clocks(5);
        check(tx === 1 && tx_busy === 0 && tx_done === 0, "outputs during reset: tx=1, busy=0, done=0");
        rst_n = 1;
        check_stays_idle(30 * n, "no frame after reset release");
        scenario_done(RESET_VALUES);
    endtask

    // 2. Reset and tx_start at the same time: reset must win
    task automatic test_reset_and_start_together();
        $display("--- 2. reset and tx_start at the same time   [t = %t]", $realtime);
        @(negedge clk);
        rst_n    = 0;
        tx_data  = 8'hA5;
        tx_start = 1;
        wait_clocks(3);
        check(tx === 1 && tx_busy === 0, "reset wins over tx_start");
        rst_n    = 1;
        tx_start = 0;
        check_stays_idle(20 * n, "no frame started from a tx_start held during reset");
        scenario_done(RESET_AND_START_TOGETHER);
    endtask

    // 3. All 256 byte values, checked by both judges
    task automatic test_all_values(input int clocks_per_bit);
        $display("--- 3. all 256 byte values, N = %0d   [t = %t]", clocks_per_bit, $realtime);
        reset_dut();
        set_clocks_per_bit(clocks_per_bit);
        for (int value = 0; value < 256; value++)
            send_byte(value);
    endtask

    // 4. Fixed patterns + one random byte in each value range, for one N
    task automatic test_patterns(input int clocks_per_bit);
        logic [7:0] patterns [8] = '{8'h00, 8'hFF, 8'h55, 8'hAA, 8'h01, 8'h80, 8'h0F, 8'hF0};
        logic [7:0] random_byte;
        if (clocks_per_bit % 8 == 0) $display("--- 4. patterns, N = %0d (pin checker + reference)   [t = %t]", clocks_per_bit, $realtime);
        else                         $display("--- 4. patterns, N = %0d (pin checker only)   [t = %t]", clocks_per_bit, $realtime);
        reset_dut();
        set_clocks_per_bit(clocks_per_bit);
        for (int i = 0; i < 8; i++)
            send_byte(patterns[i]);
        for (int range = 0; range < 4; range++) begin
            random_byte = $urandom_range(range * 64, range * 64 + 63);
            send_byte(random_byte);
        end
    endtask

    // 5. Back-to-back: tx_start held high, a new byte after each tx_done.
    //    The next start bit must come exactly 1 clock after tx_done.
    task automatic test_back_to_back();
        logic [7:0] next_byte;
        $display("--- 5. back-to-back frames (tx_start held high)   [t = %t]", $realtime);
        reset_dut();
        set_clocks_per_bit(16);
        next_byte = $urandom;
        tx_data   = next_byte;
        tx_start  = 1;
        @(negedge clk);                         // first frame accepted
        for (int frame = 1; frame <= 6; frame++) begin
            check_frame_on_pin(next_byte);      // ends on the tx_done clock
            if (frame < 6) begin
                next_byte = $urandom;
                tx_data   = next_byte;          // taken on the next rising edge
                @(negedge clk);
                check(tx === 0 && tx_busy === 1, "next start bit exactly 1 clock after tx_done");
            end else begin
                tx_start = 0;
            end
        end
        check_stays_idle(3 * n, "stops after tx_start goes low");
        scenario_done(BACK_TO_BACK);
    endtask

    // 6. Simultaneous inputs: poke tx_start and/or tx_data while TX is busy,
    //    in each state. The frame on the pin must not change, and no second
    //    frame may follow.
    task poke_while_busy(input int target_state, input poke_type_t what);
        int clocks_into_frame;
        logic [7:0] original_byte;
        original_byte = $urandom;

        if (target_state == START) clocks_into_frame = n / 2;        // middle of start bit
        if (target_state == DATA)  clocks_into_frame = 4 * n;        // in data bit 3
        if (target_state == STOP)  clocks_into_frame = 9 * n + n/2;  // middle of stop bit

        wait_until_idle();
        tx_data  = original_byte;
        tx_start = 1;
        @(negedge clk);
        tx_start = 0;

        fork
            check_frame_on_pin(original_byte);  // judge 1 runs the whole frame
            begin                                // meanwhile: poke the inputs
                wait_clocks(clocks_into_frame);
                state_when_poked = dut.state;
                poke_type        = what;
                poke_cov.sample();
                check(dut.state == target_state, "poke landed in the intended state");
                if (what == POKE_START || what == POKE_START_AND_DATA) tx_start = 1;
                if (what == POKE_DATA  || what == POKE_START_AND_DATA) tx_data  = ~original_byte;
                @(negedge clk);
                tx_start = 0;
            end
        join
        check_stays_idle(12 * n, "no extra frame after a poke while busy");
    endtask

    task automatic test_pokes_while_busy();
        $display("--- 6. tx_start / tx_data changed while busy (every state)   [t = %t]", $realtime);
        reset_dut();
        set_clocks_per_bit(16);
        for (int s = START; s <= STOP; s++) begin
            poke_while_busy(s, POKE_START);
            poke_while_busy(s, POKE_DATA);
            poke_while_busy(s, POKE_START_AND_DATA);
        end
    endtask

    // 7. tx_start on the very last clock of the stop bit (one clock too early):
    //    TX is still in STOP, so it must be ignored.
    task automatic test_start_on_last_stop_clock();
        logic [7:0] first_byte;
        $display("--- 7. tx_start one clock before the frame ends   [t = %t]", $realtime);
        reset_dut();
        set_clocks_per_bit(16);
        first_byte = 8'h3C;
        wait_until_idle();
        tx_data  = first_byte;
        tx_start = 1;
        @(negedge clk);
        tx_start = 0;
        fork
            check_frame_on_pin(first_byte);
            begin
                wait_clocks(10 * n - 1);        // last clock of the stop bit
                check(dut.state == STOP, "still in STOP on the last clock");
                tx_data  = 8'hC3;
                tx_start = 1;
                @(negedge clk);
                tx_start = 0;
            end
        join
        check_stays_idle(12 * n, "tx_start seen only in STOP is ignored");
        scenario_done(START_ON_LAST_STOP_CLOCK);
    endtask

    // 8. Reset in the middle of each state
    task automatic test_reset_in_each_state();
        int clocks_into_frame;
        $display("--- 8. reset in every state   [t = %t]", $realtime);
        set_clocks_per_bit(16);
        for (int s = START; s <= STOP; s++) begin
            reset_dut();
            if (s == START) clocks_into_frame = n / 2;
            if (s == DATA)  clocks_into_frame = 4 * n;
            if (s == STOP)  clocks_into_frame = 9 * n + n/2;

            tx_data  = $urandom;
            tx_start = 1;
            @(negedge clk);
            tx_start = 0;
            wait_clocks(clocks_into_frame);

            state_when_poked = dut.state;
            poke_type        = POKE_RESET;
            poke_cov.sample();
            check(dut.state == s, "reset lands in the intended state");

            rst_n = 0;
            wait_clocks(2);
            check(tx === 1 && tx_busy === 0 && dut.state == IDLE, "reset mid-frame: back to idle, line high");
            rst_n = 1;
            check_stays_idle(12 * n, "nothing after reset mid-frame");
            send_byte(8'h96);                   // and it works again
        end
    endtask

    // 9. N changed between frames (no reset in between)
    task automatic test_n_changes();
        int n_list [6] = '{8, 16, 176, 24, 8, 4088};
        $display("--- 9. N changed between frames   [t = %t]", $realtime);
        reset_dut();
        for (int i = 0; i < 6; i++) begin
            set_clocks_per_bit(n_list[i]);
            send_byte($urandom);
        end
        scenario_done(N_CHANGED);
    endtask

    // 10. X and Z on the inputs
    task automatic test_unknown_inputs();
        $display("--- 10. X / Z on tx_start and tx_data   [t = %t]", $realtime);
        reset_dut();
        set_clocks_per_bit(16);

        // tx_start = X: in RTL simulation "if (X)" takes the ELSE branch,
        // so TX does not start. (In silicon an X is really a 0 or a 1.)
        tx_start = 1'bx;
        wait_clocks(5);
        tx_start = 0;
        check_stays_idle(12 * n, "tx_start = X does not start a frame");
        scenario_done(START_IS_X);

        // tx_start = Z (input left floating): same thing
        tx_start = 1'bz;
        wait_clocks(5);
        tx_start = 0;
        check_stays_idle(12 * n, "tx_start = Z does not start a frame");
        scenario_done(START_IS_Z);

        // tx_data with X and Z bits: they come out on the pin unchanged,
        // but busy / done / state must stay known.
        pin_may_be_unknown = 1;
        wait_until_idle();
        tx_data  = 8'b10x1_z010;
        tx_start = 1;
        @(negedge clk);
        tx_start = 0;
        check_frame_on_pin(8'b10x1_z010);
        pin_may_be_unknown = 0;
        scenario_done(DATA_HAS_X_AND_Z);
        reset_dut();                            // clear the reference receiver
        send_byte(8'h5A);                       // clean frame afterwards
    endtask

    // =========================================================================
    // MAIN
    // =========================================================================
    initial begin
        $timeformat(-9, 0, " ns", 0);   // print times as "1234 ns"
        $display("=== tb_uart_tx: testing uart_tx on its own");

        test_reset_values();
        test_reset_and_start_together();

        test_all_values(8);
        test_all_values(16);

        test_patterns(9);
        test_patterns(17);
        test_patterns(24);
        test_patterns(174);
        test_patterns(175);
        test_patterns(176);
        test_patterns(4088);
        test_patterns(4095);

        test_back_to_back();
        test_pokes_while_busy();
        test_start_on_last_stop_clock();
        test_reset_in_each_state();
        test_n_changes();
        test_unknown_inputs();

        $display("");
        $display("=== Functional coverage");
        $display("    frames (bytes x N)   : %0.1f %%", frame_cov.get_inst_coverage());
        $display("    FSM states/arrows    : %0.1f %%", state_cov.get_inst_coverage());
        $display("    pokes while busy     : %0.1f %%", poke_cov.get_inst_coverage());
        $display("    scenarios            : %0.1f %%", scenario_cov.get_inst_coverage());
        $display("=== %0d frames checked, %0d checks, %0d errors", frame_count, check_count, error_count);
        if (error_count == 0) $display("=== TX TEST PASSED");
        else                  $display("=== TX TEST FAILED");
        $finish;
    end

    // Safety net: stop if something hangs
    initial begin
        #2_000_000_000;
        $display("ERROR: timeout, testbench hung");
        $finish;
    end

endmodule
