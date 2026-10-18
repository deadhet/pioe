// =============================================================================
// tb_uart_rx.sv — tests the PIOE UART RECEIVER (uart_rx) on its own
//
// Who talks on the rx line:
//   * REFERENCE TRANSMITTER (ref_uart_tx, third-party, test/ref/): a real UART
//     transmitter. Used for N = multiple of 8 (its bit time is prescale * 8).
//   * THREE TB DRIVERS (driver[0..2]): the TB "bit-bangs" frames with exact
//     timing. Used for every N, baud errors, glitches, X and Z, and for
//     SEVERAL TRANSMITTERS TALKING AT THE SAME TIME.
//   * A PULL-UP RESISTOR (weak 1) that can be switched on/off.
//
// rx_line is a `wire` with several drivers, so the simulator resolves them
// like real wires:
//     all drivers Z                -> Z  (floating line)
//     Z + pull-up                  -> 1  (weak 1 wins over Z)
//     driver says 0 + pull-up      -> 0  (strong beats weak)
//     two drivers agree            -> that value
//     one says 0, another says 1   -> X  (contention: unknown voltage)
//
// Checks: correct bytes, frame errors, glitch rejection, baud tolerance,
// reset in every state, and that the FSM state and the control outputs are
// NEVER X or Z, whatever happens on the line.
//
// NOTE: needs a 4-state simulator (Vivado xsim). Verilator is 2-state and
// has no X / Z, so the X / Z / contention tests mean nothing there.
// =============================================================================
`timescale 1ns/1ps

module tb_uart_rx;

    // -------------------------------------------------------------------------
    // Clock: 20 MHz (50 ns period)
    // -------------------------------------------------------------------------
    localparam real CLOCK_PERIOD = 50.0;

    logic clk = 0;
    always #(CLOCK_PERIOD / 2) clk = ~clk;

    // -------------------------------------------------------------------------
    // The rx line and everything that can drive it
    // -------------------------------------------------------------------------
    wire  rx_line;

    logic driver [3];           // TB transmitters A, B, C (1, 0, X or Z)
    assign rx_line = driver[0];
    assign rx_line = driver[1];
    assign rx_line = driver[2];

    logic pullup_on = 1;        // like a resistor from the pin to VCC
    assign (weak1, weak0) rx_line = pullup_on ? 1'b1 : 1'bz;

    logic ref_enable = 0;       // reference TX drives only when enabled
    wire  ref_txd;
    assign rx_line = ref_enable ? ref_txd : 1'bz;

    // -------------------------------------------------------------------------
    // DUT: our receiver
    // -------------------------------------------------------------------------
    logic        rst_n = 0;
    logic [11:0] n     = 16;
    wire  [7:0]  rx_data;
    wire         rx_valid;
    wire         rx_frame_err;

    uart_rx dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .n            (n),
        .rx           (rx_line),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .rx_frame_err (rx_frame_err)
    );

    // FSM state names (same numbers as inside uart_rx.v)
    localparam IDLE  = 0;
    localparam START = 1;
    localparam DATA  = 2;
    localparam STOP  = 3;

    // -------------------------------------------------------------------------
    // Reference transmitter (third-party). Bit time = prescale * 8 clocks.
    // -------------------------------------------------------------------------
    logic [7:0] ref_byte  = 0;
    logic       ref_valid = 0;
    wire        ref_ready;
    wire        ref_busy;
    wire [15:0] ref_prescale = n / 8;

    ref_uart_tx ref_tx (
        .clk           (clk),
        .rst           (!rst_n),
        .s_axis_tdata  (ref_byte),
        .s_axis_tvalid (ref_valid),
        .s_axis_tready (ref_ready),
        .txd           (ref_txd),
        .busy          (ref_busy),
        .prescale      (ref_prescale)
    );

    // -------------------------------------------------------------------------
    // What the DUT has produced (counted on every falling edge)
    // -------------------------------------------------------------------------
    int         good_byte_count   = 0;  // rx_valid pulses
    int         frame_error_count = 0;  // rx_frame_err pulses
    logic [7:0] last_byte         = 0;

    // -------------------------------------------------------------------------
    // Pass / fail bookkeeping
    // -------------------------------------------------------------------------
    int error_count = 0;
    int check_count = 0;

    function void check(input bit condition_ok, input string message);
        check_count = check_count + 1;
        if (!condition_ok) begin
            error_count = error_count + 1;
            $display("ERROR at %t: %s", $realtime, message);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Functional coverage
    // -------------------------------------------------------------------------
    covergroup byte_coverage;       // sampled on every good, fully-known byte
        byte_value: coverpoint rx_data {
            bins value[] = {[0:255]};
        }
        byte_range: coverpoint rx_data {
            bins low      = {[0:63]};
            bins mid_low  = {[64:127]};
            bins mid_high = {[128:191]};
            bins high     = {[192:255]};
        }
        clocks_per_bit: coverpoint n {
            bins n8    = {8};
            bins n9    = {9};
            bins n16   = {16};
            bins n17   = {17};
            bins n24   = {24};
            bins n174  = {174};
            bins n175  = {175};
            bins n176  = {176};
            bins n4088 = {4088};
            bins n4095 = {4095};
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
            bins idle_to_start  = (IDLE  => START);
            bins start_to_data  = (START => DATA);
            bins start_to_idle  = (START => IDLE);  // glitch rejected (or reset)
            bins data_to_stop   = (DATA  => STOP);
            bins stop_to_idle   = (STOP  => IDLE);
            bins reset_in_data  = (DATA  => IDLE);  // only reset can do this
        }
        good_byte:   coverpoint rx_valid     { bins pulse = {1}; }
        frame_error: coverpoint rx_frame_err { bins pulse = {1}; }
    endgroup

    // Several transmitters at once: how many, and what state RX was in
    int         number_of_drivers;
    logic [1:0] state_at_collision;
    bit         same_data;

    covergroup collision_coverage;
        drivers: coverpoint number_of_drivers {
            bins two   = {2};
            bins three = {3};
        }
        rx_state: coverpoint state_at_collision {
            bins idle  = {IDLE};        // all start together
            bins start = {START};
            bins data  = {DATA};
            bins stop  = {STOP};
        }
        data_match: coverpoint same_data {
            bins same      = {1};
            bins different = {0};
        }
        drivers_and_state: cross drivers, rx_state;
        drivers_and_data:  cross drivers, data_match;
    endgroup

    // Reset hit in each state
    logic [1:0] state_at_reset;
    covergroup reset_coverage;
        rx_state: coverpoint state_at_reset {
            bins idle  = {IDLE};
            bins start = {START};
            bins data  = {DATA};
            bins stop  = {STOP};
        }
    endgroup

    // Every line condition / scenario ran at least once
    typedef enum {
        RESET_VALUES,
        Z_LINE_IDLE, Z_LINE_IDLE_WITH_PULLUP, X_LINE_IDLE,
        X_START_BIT, Z_START_BIT, X_MID_START_BIT, Z_MID_START_BIT,
        X_DATA_BIT, Z_DATA_BIT, X_STOP_BIT, Z_STOP_BIT,
        RELEASED_MID_FRAME, RELEASED_MID_FRAME_WITH_PULLUP,
        OPEN_DRAIN_SENDER, WIRED_AND_TWO_SENDERS,
        GLITCH_REJECTED, SHORTEST_START_ACCEPTED,
        FRAME_ERROR, BREAK_LINE_LOW, BACK_TO_BACK_REF, BACK_TO_BACK_DRIVER,
        DATA_HELD, N_CHANGED, BAUD_FAST_OK, BAUD_SLOW_OK, BAUD_TOO_FAR
    } scenario_t;
    scenario_t scenario;

    covergroup scenario_coverage;
        which: coverpoint scenario;
    endgroup

    byte_coverage      byte_cov      = new();
    state_coverage     state_cov     = new();
    collision_coverage collision_cov = new();
    reset_coverage     reset_cov     = new();
    scenario_coverage  scenario_cov  = new();

    function void scenario_done(input scenario_t s);
        scenario = s;
        scenario_cov.sample();
    endfunction

    // -------------------------------------------------------------------------
    // Output monitor + always-on checks
    // -------------------------------------------------------------------------
    logic rx_valid_last_clock = 0;
    logic rx_error_last_clock = 0;

    always @(negedge clk) begin
        if (rst_n) begin
            // Whatever the line does, these must never be X or Z
            if ($isunknown(dut.state) || $isunknown(rx_valid) || $isunknown(rx_frame_err))
                check(0, "state / rx_valid / rx_frame_err is X or Z");
            // Pulses are exactly 1 clock
            if (rx_valid && rx_valid_last_clock)
                check(0, "rx_valid stayed high for more than 1 clock");
            if (rx_frame_err && rx_error_last_clock)
                check(0, "rx_frame_err stayed high for more than 1 clock");
            if (rx_valid && rx_frame_err)
                check(0, "rx_valid and rx_frame_err at the same time");

            if (rx_valid) begin
                good_byte_count = good_byte_count + 1;
                last_byte       = rx_data;
                if (!$isunknown(rx_data)) byte_cov.sample();
            end
            if (rx_frame_err)
                frame_error_count = frame_error_count + 1;
        end
        rx_valid_last_clock = rx_valid;
        rx_error_last_clock = rx_frame_err;
    end

    // rx_data may only change together with rx_valid (it holds the last byte)
    logic [7:0] rx_data_last_clock = 0;
    always @(negedge clk) begin
        if (rst_n && rx_data !== rx_data_last_clock && !rx_valid)
            check(0, "rx_data changed without rx_valid");
        rx_data_last_clock = rx_data;
    end

    // -------------------------------------------------------------------------
    // Helper tasks
    // -------------------------------------------------------------------------
    // "automatic" = each call gets its own copy of how_many, so two copies
    // can run at the same time inside a fork
    task automatic wait_clocks(input int how_many);
        repeat (how_many) @(negedge clk);
    endtask

    // Time of one bit, in ns (optionally with a baud error in percent)
    function real bit_time(input real error_percent = 0.0);
        return n * CLOCK_PERIOD * (1.0 + error_percent / 100.0);
    endfunction

    // Put every driver back to "only driver A drives idle-high"
    task line_back_to_normal();
        ref_enable = 0;
        pullup_on  = 1;
        driver[0]  = 1;
        driver[1]  = 1'bz;
        driver[2]  = 1'bz;
    endtask

    task reset_dut();
        @(negedge clk);
        rst_n = 0;
        wait_clocks(4);
        rst_n = 1;
        wait_clocks(2);
        clear_counters();
    endtask

    task clear_counters();
        good_byte_count   = 0;
        frame_error_count = 0;
    endtask

    task set_clocks_per_bit(input int new_n);
        wait_until_rx_idle();
        n = new_n;
    endtask

    task wait_until_rx_idle();
        @(negedge clk);
        while (dut.state != IDLE) @(negedge clk);
    endtask

    // Start somewhere random inside a clock period: a real rx pin is
    // asynchronous, its edges do not line up with our clock.
    task wait_random_phase();
        @(posedge clk);
        #($urandom_range(1, 49));
    endtask

    // Bit-bang one 8N1 frame on driver[which]
    task automatic send_frame(input int which, input logic [7:0] data,
                              input logic stop_value = 1'b1,
                              input real error_percent = 0.0);
        real one_bit;
        one_bit = bit_time(error_percent);
        driver[which] = 1'b0;                   // start bit
        #(one_bit);
        for (int i = 0; i < 8; i++) begin
            driver[which] = data[i];            // data, LSB first
            #(one_bit);
        end
        driver[which] = stop_value;             // stop bit
        #(one_bit);
        driver[which] = 1'b1;                   // back to idle
    endtask

    // Open-drain sender (like I2C): pulls the line to 0, or lets go (Z).
    // A "1" only exists because of the pull-up resistor.
    task automatic send_frame_open_drain(input int which, input logic [7:0] data);
        real one_bit;
        one_bit = bit_time();
        driver[which] = 1'b0;                   // start bit: pull low
        #(one_bit);
        for (int i = 0; i < 8; i++) begin
            driver[which] = data[i] ? 1'bz : 1'b0;
            #(one_bit);
        end
        driver[which] = 1'bz;                   // stop bit: let go
        #(one_bit);
    endtask

    // Hand one byte to the reference transmitter. Its input is an AXI-Stream
    // handshake: the byte is taken on a rising edge where valid AND ready are
    // both 1. So: put the byte out, raise valid, wait for ready, let one
    // rising edge pass.
    task hand_byte_to_reference(input logic [7:0] data);
        ref_byte  = data;
        ref_valid = 1;
        while (ref_ready !== 1'b1) @(negedge clk);
        @(negedge clk);                         // the handshake edge has passed
    endtask

    // Send one byte with the reference transmitter
    task send_with_reference(input logic [7:0] data);
        ref_enable = 1;
        driver[0]  = 1'bz;                      // driver A keeps quiet
        @(negedge clk);
        while (ref_busy) @(negedge clk);
        hand_byte_to_reference(data);
        ref_valid = 0;
        while (ref_busy) @(negedge clk);        // whole frame sent
    endtask

    // ---- Result checks: call after the frame (and a short wait) ------------
    task check_got_byte(input logic [7:0] expected, input string what);
        check(good_byte_count == 1 && frame_error_count == 0 && last_byte === expected,
              $sformatf("%s: got %0d byte(s) (last %h) and %0d frame error(s), expected exactly 1 byte %h",
                        what, good_byte_count, last_byte, frame_error_count, expected));
        clear_counters();
    endtask

    task check_got_frame_error(input string what);
        check(good_byte_count == 0 && frame_error_count == 1,
              $sformatf("%s: got %0d byte(s) and %0d frame error(s), expected exactly 1 frame error",
                        what, good_byte_count, frame_error_count));
        clear_counters();
    endtask

    task check_got_nothing(input string what);
        check(good_byte_count == 0 && frame_error_count == 0,
              $sformatf("%s: got %0d byte(s) and %0d frame error(s), expected nothing",
                        what, good_byte_count, frame_error_count));
        clear_counters();
    endtask

    // After any messy line condition: RX must be back in IDLE and receive a
    // clean byte again (no lock-up, no left-over X)
    task check_recovers(input string what);
        logic [7:0] clean_byte;
        line_back_to_normal();
        wait_clocks(12 * n);                    // let any half-frame finish
        check(dut.state == IDLE, $sformatf("%s: RX back in IDLE", what));
        clear_counters();
        clean_byte = $urandom;
        wait_random_phase();
        send_frame(0, clean_byte);
        wait_clocks(2 * n);
        check_got_byte(clean_byte, $sformatf("%s: clean byte afterwards", what));
    endtask

    // =========================================================================
    // TESTS
    // =========================================================================

    // 1. Reset values; nothing happens after release (line idle high)
    task automatic test_reset_values();
        $display("--- 1. reset values   [t = %t]", $realtime);
        line_back_to_normal();
        rst_n = 0;
        wait_clocks(5);
        check(rx_valid === 0 && rx_frame_err === 0 && rx_data === 8'h00 && dut.state == IDLE,
              "outputs during reset");
        rst_n = 1;
        wait_clocks(30 * n);
        check_got_nothing("after reset release");
        scenario_done(RESET_VALUES);
    endtask

    // 2. All 256 values from the reference transmitter
    task automatic test_all_values_from_reference(input int clocks_per_bit);
        $display("--- 2. all 256 values from the reference TX, N = %0d   [t = %t]", clocks_per_bit, $realtime);
        set_clocks_per_bit(clocks_per_bit);
        reset_dut();
        for (int value = 0; value < 256; value++) begin
            send_with_reference(value);
            wait_clocks(2);
            check_got_byte(value, "reference TX");
        end
        line_back_to_normal();
    endtask

    // 3. Patterns + one random byte per range, from the reference TX
    task automatic test_reference_patterns(input int clocks_per_bit);
        logic [7:0] patterns [8] = '{8'h00, 8'hFF, 8'h55, 8'hAA, 8'h01, 8'h80, 8'h0F, 8'hF0};
        logic [7:0] random_byte;
        $display("--- 3. patterns from the reference TX, N = %0d   [t = %t]", clocks_per_bit, $realtime);
        set_clocks_per_bit(clocks_per_bit);
        reset_dut();
        for (int i = 0; i < 8; i++) begin
            send_with_reference(patterns[i]);
            wait_clocks(2);
            check_got_byte(patterns[i], "reference TX pattern");
        end
        for (int range = 0; range < 4; range++) begin
            random_byte = $urandom_range(range * 64, range * 64 + 63);
            send_with_reference(random_byte);
            wait_clocks(2);
            check_got_byte(random_byte, "reference TX random");
        end
        line_back_to_normal();
    endtask

    // 4. Patterns from the TB driver (any N, including odd N)
    task automatic test_driver_patterns(input int clocks_per_bit);
        logic [7:0] patterns [8] = '{8'h00, 8'hFF, 8'h55, 8'hAA, 8'h01, 8'h80, 8'h0F, 8'hF0};
        logic [7:0] random_byte;
        $display("--- 4. patterns from the TB driver, N = %0d   [t = %t]", clocks_per_bit, $realtime);
        set_clocks_per_bit(clocks_per_bit);
        reset_dut();
        line_back_to_normal();
        for (int i = 0; i < 8; i++) begin
            wait_random_phase();
            send_frame(0, patterns[i]);
            wait_clocks(2 * n);
            check_got_byte(patterns[i], "TB driver pattern");
        end
        for (int range = 0; range < 4; range++) begin
            random_byte = $urandom_range(range * 64, range * 64 + 63);
            wait_random_phase();
            send_frame(0, random_byte);
            wait_clocks(2 * n);
            check_got_byte(random_byte, "TB driver random");
        end
    endtask

    // 5. Back-to-back frames, no idle time between them
    task automatic test_back_to_back();
        logic [7:0] bytes [6] = '{8'h12, 8'h34, 8'h56, 8'h78, 8'h9A, 8'hBC};
        $display("--- 5. back-to-back frames   [t = %t]", $realtime);
        set_clocks_per_bit(16);
        reset_dut();

        // TB driver: next start bit right after the stop bit
        line_back_to_normal();
        wait_random_phase();
        for (int i = 0; i < 6; i++)
            send_frame(0, bytes[i]);
        wait_clocks(2 * n);
        check(good_byte_count == 6 && frame_error_count == 0 && last_byte === 8'hBC,
              "6 back-to-back frames from the TB driver");
        clear_counters();
        scenario_done(BACK_TO_BACK_DRIVER);

        // Reference TX with its "valid" held high: it sends frames back-to-back
        ref_enable = 1;
        driver[0]  = 1'bz;
        @(negedge clk);
        for (int i = 0; i < 6; i++)
            hand_byte_to_reference(bytes[i]);   // valid stays high in between
        ref_valid = 0;
        while (ref_busy) @(negedge clk);
        wait_clocks(2 * n);
        check(good_byte_count == 6 && frame_error_count == 0 && last_byte === 8'hBC,
              "6 back-to-back frames from the reference TX");
        clear_counters();
        line_back_to_normal();
        scenario_done(BACK_TO_BACK_REF);
    endtask

    // 6. Glitches: short low pulses must be ignored.
    //    RX looks again at the middle of the start bit. Worked out from the
    //    RTL: a pulse of L clocks is ignored when L <= N/2 - 2.
    //    One clock longer and it counts as a start bit; the line is high for
    //    the rest of the frame, so RX must then deliver 0xFF.
    task automatic test_glitches(input int clocks_per_bit);
        int longest_ignored;
        $display("--- 6. glitch rejection, N = %0d   [t = %t]", clocks_per_bit, $realtime);
        set_clocks_per_bit(clocks_per_bit);
        reset_dut();
        line_back_to_normal();
        longest_ignored = (n / 2) - 2;

        for (int length = 1; length <= longest_ignored; length++) begin
            wait_random_phase();
            driver[0] = 0;
            #(length * CLOCK_PERIOD);
            driver[0] = 1;
            wait_clocks(n);
        end
        wait_clocks(12 * n);
        check_got_nothing($sformatf("glitches of 1..%0d clocks", longest_ignored));
        scenario_done(GLITCH_REJECTED);

        wait_random_phase();
        driver[0] = 0;
        #((longest_ignored + 1) * CLOCK_PERIOD);
        driver[0] = 1;
        wait_clocks(12 * n);
        check_got_byte(8'hFF, $sformatf("low pulse of %0d clocks = shortest start bit", longest_ignored + 1));
        scenario_done(SHORTEST_START_ACCEPTED);
    endtask

    // 7. Frame error (stop bit = 0), then a good frame again
    task automatic test_frame_error(input int clocks_per_bit);
        $display("--- 7. frame error, N = %0d   [t = %t]", clocks_per_bit, $realtime);
        set_clocks_per_bit(clocks_per_bit);
        reset_dut();
        line_back_to_normal();
        wait_random_phase();
        send_frame(0, 8'h5A, 1'b0);             // bad stop bit
        wait_clocks(2 * n);
        check_got_frame_error("stop bit = 0");
        wait_random_phase();
        send_frame(0, 8'hA5);
        wait_clocks(2 * n);
        check_got_byte(8'hA5, "good frame after a frame error");
        scenario_done(FRAME_ERROR);
    endtask

    // 8. Break: line held low for 3 frame-times. One frame error, then nothing.
    task automatic test_break();
        $display("--- 8. break (line stuck low)   [t = %t]", $realtime);
        set_clocks_per_bit(16);
        reset_dut();
        line_back_to_normal();
        wait_random_phase();
        driver[0] = 0;
        wait_clocks(30 * n);
        driver[0] = 1;
        wait_clocks(12 * n);
        check_got_frame_error("line low for 3 frames");
        check_recovers("break");
        scenario_done(BREAK_LINE_LOW);
    endtask

    // 9. rx_data keeps the old byte while the next frame comes in,
    //    and a bad frame does not overwrite it
    task automatic test_data_held();
        $display("--- 9. rx_data held   [t = %t]", $realtime);
        set_clocks_per_bit(16);
        reset_dut();
        line_back_to_normal();
        send_frame(0, 8'h11);
        wait_clocks(2 * n);
        check_got_byte(8'h11, "first byte");
        fork
            send_frame(0, 8'h22);
            begin
                wait_clocks(5 * n);             // halfway through the next frame
                check(rx_data === 8'h11, "old byte still readable during the next frame");
            end
        join
        wait_clocks(2 * n);
        check_got_byte(8'h22, "second byte");
        send_frame(0, 8'h33, 1'b0);             // bad frame
        wait_clocks(2 * n);
        check_got_frame_error("bad frame");
        check(rx_data === 8'h22, "a bad frame does not overwrite rx_data");
        scenario_done(DATA_HELD);
    endtask

    // 10. Reset in each state, then a clean byte
    task automatic test_reset_in_each_state();
        int clocks_into_frame;
        $display("--- 10. reset in every state   [t = %t]", $realtime);
        set_clocks_per_bit(16);
        for (int s = IDLE; s <= STOP; s++) begin
            reset_dut();
            line_back_to_normal();
            if (s == IDLE)  clocks_into_frame = 0;
            if (s == START) clocks_into_frame = 4;          // in the start bit, before ½ bit
            if (s == DATA)  clocks_into_frame = 4 * n;
            if (s == STOP)  clocks_into_frame = 9 * n + 2;  // between mid bit 7 and mid stop
            fork
                begin
                    if (s != IDLE) send_frame(0, 8'h00);
                end
                begin
                    wait_clocks(clocks_into_frame);
                    state_at_reset = dut.state;
                    reset_cov.sample();
                    check(dut.state == s, $sformatf("reset lands in state %0d", s));
                    rst_n = 0;
                    wait_clocks(2);
                    check(dut.state == IDLE && rx_valid === 0 && rx_frame_err === 0,
                          "reset mid-frame: back to IDLE");
                    rst_n = 1;
                end
            join
            wait_clocks(12 * n);
            clear_counters();       // the cut frame's tail may decode as anything
            check_recovers($sformatf("reset in state %0d", s));
        end
    endtask

    // 11. N changes between frames
    task automatic test_n_changes();
        int n_list [6] = '{8, 16, 9, 174, 17, 4095};
        logic [7:0] random_byte;
        $display("--- 11. N changed between frames   [t = %t]", $realtime);
        reset_dut();
        line_back_to_normal();
        for (int i = 0; i < 6; i++) begin
            set_clocks_per_bit(n_list[i]);
            random_byte = $urandom;
            wait_random_phase();
            send_frame(0, random_byte);
            wait_clocks(2 * n);
            check_got_byte(random_byte, $sformatf("N changed to %0d", n));
        end
        scenario_done(N_CHANGED);
    endtask

    // 12. Baud error: the sender's clock is a bit fast or slow
    task automatic test_baud_error(input int clocks_per_bit);
        real error_list [13] = '{-8.0, -6.0, -5.0, -4.0, -3.0, -2.0, 0.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0};
        logic [7:0] bytes [4] = '{8'h55, 8'hAA, 8'h00, 8'hFF};
        bit all_ok;
        $display("--- 12. baud error sweep, N = %0d   [t = %t]", clocks_per_bit, $realtime);
        set_clocks_per_bit(clocks_per_bit);
        for (int e = 0; e < 13; e++) begin
            all_ok = 1;
            for (int b = 0; b < 4; b++) begin
                reset_dut();
                line_back_to_normal();
                wait_random_phase();
                send_frame(0, bytes[b], 1'b1, error_list[e]);
                wait_clocks(12 * n);
                if (!(good_byte_count == 1 && frame_error_count == 0 && last_byte === bytes[b]))
                    all_ok = 0;
            end
            if (all_ok) $display("      sender %5.1f %% off  ->  received OK", error_list[e]);
            else        $display("      sender %5.1f %% off  ->  fails", error_list[e]);
            // Spec budget: about +-2 % must always work. We demand +-3 %.
            if (error_list[e] >= -3.0 && error_list[e] <= 3.0)
                check(all_ok, $sformatf("%0.1f %% baud error must work", error_list[e]));
            if (all_ok && error_list[e] < 0) scenario_done(BAUD_FAST_OK);
            if (all_ok && error_list[e] > 0) scenario_done(BAUD_SLOW_OK);
            if (!all_ok)                     scenario_done(BAUD_TOO_FAR);
        end
        clear_counters();
    endtask

    // 13. X and Z on the line
    //     RTL rule to remember: "if (X)" takes the ELSE branch. Real silicon
    //     has no X; an X means "could be 0 or 1", so these tests show what
    //     the RTL does and that it never gets stuck or spreads X into the FSM.
    task automatic test_unknown_line(input logic bad_value);
        string name;
        name = (bad_value === 1'bz) ? "Z" : "X";
        $display("--- 13. %s on the rx line   [t = %t]", name, $realtime);
        set_clocks_per_bit(16);
        reset_dut();

        // a) Idle line is X or Z for a long time: nothing may happen
        line_back_to_normal();
        if (bad_value === 1'bz) begin
            pullup_on = 0;
            driver[0] = 1'bz;                   // nobody drives: floating pin
        end else
            driver[0] = 1'bx;
        wait_clocks(20 * n);
        check_got_nothing($sformatf("idle line = %s", name));
        check(dut.state == IDLE, $sformatf("idle line = %s: stays in IDLE", name));
        check_recovers($sformatf("idle line = %s", name));
        scenario_done(bad_value === 1'bz ? Z_LINE_IDLE : X_LINE_IDLE);

        // b) Whole start bit is X/Z, data 0xFF: no real 1->0 edge, so no frame
        line_back_to_normal();
        wait_random_phase();
        driver[0] = bad_value;
        if (bad_value === 1'bz) pullup_on = 0;
        #(bit_time());
        pullup_on = 1;
        send_rest_of_frame(8'hFF, 1'b1);
        wait_clocks(2 * n);
        check_got_nothing($sformatf("start bit = %s", name));
        check_recovers($sformatf("start bit = %s", name));
        scenario_done(bad_value === 1'bz ? Z_START_BIT : X_START_BIT);

        // c) Start bit begins as a real 0, turns X/Z before the ½-bit check:
        //    the check sees X, takes the else branch -> treated as a glitch
        line_back_to_normal();
        wait_random_phase();
        driver[0] = 0;
        #(bit_time() / 4);
        driver[0] = bad_value;
        if (bad_value === 1'bz) pullup_on = 0;
        #(bit_time() * 3 / 4);
        pullup_on = 1;
        send_rest_of_frame(8'hFF, 1'b1);
        wait_clocks(2 * n);
        check_got_nothing($sformatf("start bit turns %s before the middle", name));
        check_recovers($sformatf("start bit turns %s", name));
        scenario_done(bad_value === 1'bz ? Z_MID_START_BIT : X_MID_START_BIT);

        // d) One data bit (bit 3) is X/Z: the byte arrives with that bit unknown
        line_back_to_normal();
        if (bad_value === 1'bz) pullup_on = 0;
        wait_random_phase();
        send_frame_with_bad_bit(8'b0101_0101, 3, bad_value);
        wait_clocks(2 * n);
        check(good_byte_count == 1 && frame_error_count == 0,
              $sformatf("data bit 3 = %s: one byte still delivered", name));
        check(last_byte[3] === bad_value || last_byte[3] === 1'bx,
              $sformatf("data bit 3 = %s: that bit is unknown in rx_data (got %b)", name, last_byte));
        check(last_byte[7:4] === 4'b0101 && last_byte[2:0] === 3'b101,
              $sformatf("data bit 3 = %s: the other 7 bits are correct (got %b)", name, last_byte));
        clear_counters();
        check_recovers($sformatf("data bit = %s", name));
        check(!$isunknown(rx_data), "rx_data fully known again after a clean byte");
        scenario_done(bad_value === 1'bz ? Z_DATA_BIT : X_DATA_BIT);

        // e) Stop bit is X/Z: "if (rx_sync)" sees X -> else -> frame error
        line_back_to_normal();
        if (bad_value === 1'bz) pullup_on = 0;
        wait_random_phase();
        send_frame(0, 8'h3C, bad_value);
        wait_clocks(2 * n);
        check_got_frame_error($sformatf("stop bit = %s", name));
        check_recovers($sformatf("stop bit = %s", name));
        scenario_done(bad_value === 1'bz ? Z_STOP_BIT : X_STOP_BIT);
    endtask

    // Data bits + stop bit (used after a hand-made start bit)
    task send_rest_of_frame(input logic [7:0] data, input logic stop_value);
        for (int i = 0; i < 8; i++) begin
            driver[0] = data[i];
            #(bit_time());
        end
        driver[0] = stop_value;
        #(bit_time());
        driver[0] = 1'b1;
    endtask

    // A normal frame, except one data bit is replaced by bad_value
    task send_frame_with_bad_bit(input logic [7:0] data, input int bad_bit, input logic bad_value);
        driver[0] = 1'b0;
        #(bit_time());
        for (int i = 0; i < 8; i++) begin
            driver[0] = (i == bad_bit) ? bad_value : data[i];
            #(bit_time());
        end
        driver[0] = 1'b1;
        #(bit_time());
    endtask

    // 14. Transmitter disconnected in the middle of a frame (driver lets go)
    task automatic test_released_mid_frame();
        $display("--- 14. sender lets go of the line mid-frame   [t = %t]", $realtime);
        set_clocks_per_bit(16);
        reset_dut();

        // Without pull-up: the rest of the frame is Z -> stop bit unknown -> frame error
        line_back_to_normal();
        pullup_on = 0;
        wait_random_phase();
        driver[0] = 0;  #(bit_time());                          // start
        for (int i = 0; i < 4; i++) begin driver[0] = 0; #(bit_time()); end  // bits 0-3 = 0
        driver[0] = 1'bz;                                       // cable pulled
        #(5 * bit_time());                                      // bits 4-7 + stop
        wait_clocks(2 * n);
        check_got_frame_error("released mid-frame, no pull-up");
        check_recovers("released mid-frame, no pull-up");
        scenario_done(RELEASED_MID_FRAME);

        // With pull-up: the released line reads 1 -> byte 0xF0, valid frame
        line_back_to_normal();
        wait_random_phase();
        driver[0] = 0;  #(bit_time());
        for (int i = 0; i < 4; i++) begin driver[0] = 0; #(bit_time()); end
        driver[0] = 1'bz;
        #(5 * bit_time());
        wait_clocks(2 * n);
        check_got_byte(8'hF0, "released mid-frame, pull-up turns Z into 1");
        line_back_to_normal();
        scenario_done(RELEASED_MID_FRAME_WITH_PULLUP);

        // Floating idle line WITH pull-up reads as a clean 1
        driver[0] = 1'bz;
        wait_clocks(5);
        check(rx_line === 1'b1, "floating line + pull-up reads 1");
        wait_clocks(20 * n);
        check_got_nothing("floating line + pull-up");
        line_back_to_normal();
        scenario_done(Z_LINE_IDLE_WITH_PULLUP);
    endtask

    // 15. Open-drain senders (0 or Z) with a pull-up
    task automatic test_open_drain();
        logic [7:0] byte_a, byte_b;
        $display("--- 15. open-drain senders + pull-up (wired-AND)   [t = %t]", $realtime);
        set_clocks_per_bit(16);
        reset_dut();
        line_back_to_normal();
        driver[0] = 1'bz;                       // everybody open-drain now

        // One open-drain sender: works like a normal UART
        byte_a = 8'hC5;
        wait_random_phase();
        send_frame_open_drain(0, byte_a);
        wait_clocks(2 * n);
        check_got_byte(byte_a, "one open-drain sender");
        scenario_done(OPEN_DRAIN_SENDER);

        // Two open-drain senders at once: any 0 wins, so the line = A AND B
        byte_a = 8'b1100_1010;
        byte_b = 8'b1010_0110;
        wait_random_phase();
        fork
            send_frame_open_drain(0, byte_a);
            send_frame_open_drain(1, byte_b);
        join
        wait_clocks(2 * n);
        check_got_byte(byte_a & byte_b, "two open-drain senders: line = A AND B, no X");
        number_of_drivers  = 2;
        state_at_collision = IDLE;
        same_data          = 0;
        collision_cov.sample();
        line_back_to_normal();
        scenario_done(WIRED_AND_TWO_SENDERS);
    endtask

    // 16. Two or three push-pull transmitters at the SAME time.
    //     Where they disagree (0 vs 1) the line is X.
    task automatic test_simultaneous(input int how_many, input bit send_same_data);
        logic [7:0] bytes [3];
        logic [7:0] expected;
        if (send_same_data) $display("--- 16. %0d transmitters start together, same data   [t = %t]", how_many, $realtime);
        else                $display("--- 16. %0d transmitters start together, different data   [t = %t]", how_many, $realtime);
        set_clocks_per_bit(16);
        reset_dut();
        line_back_to_normal();
        for (int d = 1; d < how_many; d++) driver[d] = 1;   // extra drivers idle high

        bytes[0] = 8'b1100_1010;
        bytes[1] = send_same_data ? bytes[0] : 8'b1010_0110;
        bytes[2] = send_same_data ? bytes[0] : 8'b0110_1100;

        // Expected rx_data: a bit is known only if every driver agrees on it
        for (int i = 0; i < 8; i++) begin
            expected[i] = bytes[0][i];
            for (int d = 1; d < how_many; d++)
                if (bytes[d][i] !== bytes[0][i]) expected[i] = 1'bx;
        end

        number_of_drivers  = how_many;
        state_at_collision = dut.state;         // IDLE: they all start together
        same_data          = send_same_data;
        collision_cov.sample();

        wait_random_phase();
        fork
            send_frame(0, bytes[0]);
            send_frame(1, bytes[1]);
            if (how_many == 3) send_frame(2, bytes[2]);
        join
        wait_clocks(2 * n);
        check(good_byte_count == 1 && frame_error_count == 0,
              $sformatf("%0d senders together: one frame (stop bits agree)", how_many));
        check(last_byte === expected,
              $sformatf("%0d senders together: rx_data = %b, expected %b", how_many, last_byte, expected));
        clear_counters();
        check_recovers($sformatf("%0d senders together", how_many));
    endtask

    // 17. A second (and third) transmitter starts while RX is busy with the
    //     first frame, once in each RX state. We cannot predict the byte
    //     (the line is a mix of 0, 1 and X), so we check what MUST hold:
    //     state never X, control outputs never X, at most a few results,
    //     RX back in IDLE, and a clean byte afterwards.
    task automatic test_collision(input int how_many, input int target_state);
        real start_delay;
        string state_name;
        if (target_state == START) begin start_delay = bit_time() * 0.25; state_name = "START"; end
        if (target_state == DATA)  begin start_delay = bit_time() * 3.0;  state_name = "DATA";  end
        if (target_state == STOP)  begin start_delay = bit_time() * 9.0;  state_name = "STOP";  end
        $display("--- 17. %0d transmitters, extra one(s) start while RX is in %s   [t = %t]", how_many, state_name, $realtime);
        set_clocks_per_bit(16);
        reset_dut();
        line_back_to_normal();
        // The latecomers stay Z (not connected / not enabled) until they start.
        // If they drove a strong 1 while waiting, the first sender's start bit
        // (0) would already clash with them and the line would be X at once.

        wait_random_phase();
        fork
            send_frame(0, 8'hA5);                       // first transmitter
            begin                                       // the latecomer(s)
                #(start_delay);
                number_of_drivers  = how_many;
                state_at_collision = dut.state;
                same_data          = 0;
                collision_cov.sample();
                check(dut.state == target_state,
                      $sformatf("collision happens while RX is in %s", state_name));
                fork
                    send_frame(1, 8'h3C);
                    if (how_many == 3) send_frame(2, 8'h0F);
                join
            end
        join
        wait_clocks(12 * n);
        $display("      RX output: %0d byte(s), %0d frame error(s), last rx_data = %b",
                 good_byte_count, frame_error_count, last_byte);
        check(good_byte_count + frame_error_count <= 3,
              "collision: RX produced at most a few results (no runaway)");
        clear_counters();
        check_recovers($sformatf("%0d transmitters, collision in %s", how_many, state_name));
    endtask

    // =========================================================================
    // MAIN
    // =========================================================================
    initial begin
        $timeformat(-9, 0, " ns", 0);   // print times as "1234 ns"
        $display("=== tb_uart_rx: testing uart_rx on its own");
        line_back_to_normal();

        test_reset_values();

        test_all_values_from_reference(8);
        test_all_values_from_reference(16);
        test_reference_patterns(24);
        test_reference_patterns(176);
        test_reference_patterns(4088);

        test_driver_patterns(8);
        test_driver_patterns(9);
        test_driver_patterns(16);
        test_driver_patterns(17);
        test_driver_patterns(174);
        test_driver_patterns(175);
        test_driver_patterns(4095);

        test_back_to_back();
        test_glitches(8);
        test_glitches(16);
        test_glitches(17);
        test_glitches(174);
        test_frame_error(8);
        test_frame_error(16);
        test_frame_error(174);
        test_break();
        test_data_held();
        test_reset_in_each_state();
        test_n_changes();
        test_baud_error(16);
        test_baud_error(174);

        test_unknown_line(1'bx);
        test_unknown_line(1'bz);
        test_released_mid_frame();
        test_open_drain();

        test_simultaneous(2, 1);
        test_simultaneous(2, 0);
        test_simultaneous(3, 1);
        test_simultaneous(3, 0);
        for (int s = START; s <= STOP; s++) begin
            test_collision(2, s);
            test_collision(3, s);
        end

        $display("");
        $display("=== Functional coverage");
        $display("    bytes x N            : %0.1f %%", byte_cov.get_inst_coverage());
        $display("    FSM states/arrows    : %0.1f %%", state_cov.get_inst_coverage());
        $display("    collisions           : %0.1f %%", collision_cov.get_inst_coverage());
        $display("    reset in each state  : %0.1f %%", reset_cov.get_inst_coverage());
        $display("    scenarios            : %0.1f %%", scenario_cov.get_inst_coverage());
        $display("=== %0d checks, %0d errors", check_count, error_count);
        if (error_count == 0) $display("=== RX TEST PASSED");
        else                  $display("=== RX TEST FAILED");
        $finish;
    end

    // Safety net: stop if something hangs
    initial begin
        #2_000_000_000;
        $display("ERROR: timeout, testbench hung");
        $finish;
    end

endmodule
