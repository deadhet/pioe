// =============================================================================
// tb_uart.sv — self-checking testbench for uart_tx + uart_rx
// Spec: docs/specs/protocols/uart_tx.md, uart_rx.md
//
// Idea: each block is checked against an INDEPENDENT model in the testbench,
// so a bug shared by TX and RX (e.g. both MSB-first) cannot hide:
//   uart_tx -> TX monitor rebuilds every frame from the tx pin, clock by clock
//   uart_rx -> RX driver bit-bangs frames onto rx with real-time (async) edges
//   loopback (tx -> rx) is only the final system check.
//
// Pass/fail is decided by the TB: scoreboards (queues), SVA assertions, and a
// final summary. Functional coverage (covergroups) shows WHAT was exercised.
//
// Run: Vivado "Run Behavioral Simulation", or
//      vivado -mode batch -source pioe/scripts/vivado_uart.tcl -tclargs sim
// Random seed: set by the simulator (xsim -sv_seed 123, Verilator +verilator+seed+123)
// =============================================================================
`timescale 1ns/1ps

module tb_uart;

    // ---- Settings -----------------------------------------------------------
    localparam int  CNT_W  = 12;
    localparam real CLK_NS = 50.0;          // 20 MHz, as in the spec examples

    // ---- Signals ------------------------------------------------------------
    logic             clk = 0;
    logic             rst_n = 0;
    logic [CNT_W-1:0] n = 16;               // clocks per bit, shared by TX and RX
    logic [7:0]       tx_data = 0;
    logic             tx_start = 0;
    wire              tx, tx_busy, tx_done;

    logic             rx_drv  = 1;          // TB-driven serial line (idle high)
    logic             loop_en = 0;          // 1: rx is fed by tx (loopback)
    wire              rx_line = loop_en ? tx : rx_drv;
    wire  [7:0]       rx_data;
    wire              rx_valid, rx_frame_err;

    always #(CLK_NS/2) clk = ~clk;

    // ---- DUTs ---------------------------------------------------------------
    uart_tx #(.CNT_W(CNT_W)) u_tx (
        .clk(clk), .rst_n(rst_n), .n(n),
        .tx_data(tx_data), .tx_start(tx_start),
        .tx(tx), .tx_busy(tx_busy), .tx_done(tx_done)
    );

    uart_rx #(.CNT_W(CNT_W)) u_rx (
        .clk(clk), .rst_n(rst_n), .n(n), .rx(rx_line),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_frame_err(rx_frame_err)
    );

    // ---- Bookkeeping --------------------------------------------------------
    int         errors = 0, checks = 0;
    logic [7:0] tx_exp[$];                  // bytes we expect to see on the tx pin
    logic [7:0] rx_exp[$];                  // bytes we expect from rx_data
    int         exp_ferr = 0;               // frame errors we expect
    int         rx_valid_cnt = 0, rx_ferr_cnt = 0, tx_frames = 0;
    logic [7:0] last_rx;
    bit         sweep_mode = 0;             // baud sweep: count results, don't fail
    logic [7:0] tx_mon_byte, rx_e, tx_e;

    // Fixed patterns: all-0/1, alternating, LSB-only / MSB-only (bit order!)
    logic [7:0] patterns[] = '{8'h00, 8'hFF, 8'h55, 8'hAA, 8'h01, 8'h80, 8'h0F, 8'hF0};

    function automatic void check(bit cond, string msg);
        checks++;
        if (!cond) begin
            errors++;
            $error("[%0t ns] FAIL: %s", $time, msg);
        end
    endfunction

    // ---- Functional coverage ------------------------------------------------
    typedef enum {
        E_RST_IDLE,         // reset release did not fake a start bit
        E_TX_LATCH,         // tx_data changed mid-frame, frame unaffected
        E_TX_START_BUSY,    // tx_start while busy ignored
        E_TX_B2B,           // TX back-to-back with tx_start held
        E_TX_RST_MID,       // reset during a TX frame
        E_RX_B2B,           // RX back-to-back, no idle between frames
        E_RX_RST_MID,       // reset during an RX frame
        E_RX_HOLD,          // rx_data held while next frame arrives
        E_GLITCH_REJ,       // short low pulse rejected
        E_GLITCH_EDGE_ACC,  // shortest accepted start (threshold)
        E_FRAME_ERR,        // stop bit = 0 detected
        E_N_CHANGE,         // N changed between frames
        E_BAUD_FAST_OK,     // sender faster than RX, still received
        E_BAUD_SLOW_OK,     // sender slower than RX, still received
        E_BAUD_FAIL         // too much baud error, failure seen
    } evt_e;
    evt_e evt;

    covergroup cg_rx;       // sampled on every rx_valid
        cp_data:   coverpoint rx_data { bins val[] = {[0:255]}; }
        cp_n:      coverpoint n {
            bins n_min = {8};  bins n_odd = {9, 17};  bins n_rec = {16};
            bins n_115k2 = {174};  bins n_max = {4095};
        }
        cp_region: coverpoint rx_data[7:5];          // 8 value regions
        x_region_n: cross cp_region, cp_n;
    endgroup

    covergroup cg_tx;       // sampled on every frame the TX monitor rebuilds
        cp_data:   coverpoint tx_mon_byte { bins val[] = {[0:255]}; }
        cp_n:      coverpoint n {
            bins n_min = {8};  bins n_odd = {9, 17};  bins n_rec = {16};
            bins n_115k2 = {174};  bins n_max = {4095};
        }
        cp_region: coverpoint tx_mon_byte[7:5];
        x_region_n: cross cp_region, cp_n;
    endgroup

    covergroup cg_evt;
        cp_evt: coverpoint evt;                      // one bin per scenario
    endgroup

    cg_rx  cg_rx_i  = new();
    cg_tx  cg_tx_i  = new();
    cg_evt cg_evt_i = new();

    function automatic void hit(evt_e e);
        evt = e;
        cg_evt_i.sample();
    endfunction

    // ---- Assertions (checked every clock) -----------------------------------
    // Pulses are exactly one clock long
    a_txdone_1clk: assert property (@(posedge clk) disable iff (!rst_n) tx_done |=> !tx_done)
        else begin errors++; $error("tx_done longer than 1 clock"); end
    a_rxvalid_1clk: assert property (@(posedge clk) disable iff (!rst_n) rx_valid |=> !rx_valid)
        else begin errors++; $error("rx_valid longer than 1 clock"); end
    a_rxferr_1clk: assert property (@(posedge clk) disable iff (!rst_n) rx_frame_err |=> !rx_frame_err)
        else begin errors++; $error("rx_frame_err longer than 1 clock"); end
    // Line idles high whenever TX is not busy
    a_idle_high: assert property (@(posedge clk) disable iff (!rst_n) !tx_busy |-> tx)
        else begin errors++; $error("tx low while idle"); end
    // Accepted start: busy and start bit on the very next clock
    a_start_accept: assert property (@(posedge clk) disable iff (!rst_n)
                                     (!tx_busy && tx_start) |=> (tx_busy && !tx))
        else begin errors++; $error("tx_start not accepted in 1 clock"); end
    // tx_done only comes with the return to idle
    a_done_idle: assert property (@(posedge clk) disable iff (!rst_n) tx_done |-> !tx_busy)
        else begin errors++; $error("tx_done while busy"); end
    // A frame is either good or bad, never both
    a_rx_excl: assert property (@(posedge clk) disable iff (!rst_n) !(rx_valid && rx_frame_err))
        else begin errors++; $error("rx_valid and rx_frame_err together"); end
    // rx_data only changes together with rx_valid (held otherwise)
    a_rx_hold: assert property (@(posedge clk) disable iff (!rst_n) !$stable(rx_data) |-> rx_valid)
        else begin errors++; $error("rx_data changed without rx_valid"); end

    // ---- TX monitor: rebuild each frame from the pin, clock by clock --------
    // TB samples on negedge (DUT changes on posedge), so there are no races.
    task automatic mon_frame();
        logic [9:0] bits;
        int nn = n;
        for (int b = 0; b < 10; b++) begin
            for (int c = 0; c < nn; c++) begin
                if (!(b == 0 && c == 0)) @(negedge clk);
                if (c == 0) bits[b] = tx;
                else if (tx !== bits[b])
                    check(0, $sformatf("TX bit %0d changed after %0d of %0d clocks", b, c, nn));
                if (tx_busy !== 1'b1) check(0, "TX busy dropped mid-frame");
            end
        end
        @(negedge clk);     // first clock after 10*N: frame must be over
        check(tx_done === 1'b1 && tx_busy === 1'b0 && tx === 1'b1,
              "TX frame end: expect tx_done pulse, busy=0, line high after exactly 10*N clocks");
        check(bits[0] === 1'b0, "TX start bit must be 0");
        check(bits[9] === 1'b1, "TX stop bit must be 1");
        tx_mon_byte = bits[8:1];            // LSB first on the wire
        tx_frames++;
        cg_tx_i.sample();
        if (tx_exp.size() == 0)
            check(0, $sformatf("TX sent an unexpected frame %02h", tx_mon_byte));
        else begin
            tx_e = tx_exp.pop_front();
            check(tx_mon_byte === tx_e, $sformatf("TX byte %02h, expected %02h", tx_mon_byte, tx_e));
        end
    endtask

    initial begin : tx_monitor
        forever begin
            @(negedge clk iff (rst_n && tx_busy && tx === 1'b0));   // start bit seen
            fork
                mon_frame();
                @(negedge rst_n);           // reset mid-frame: abandon this frame
            join_any
            disable fork;
        end
    end

    // ---- RX checker / scoreboard --------------------------------------------
    always @(negedge clk) if (rst_n) begin
        if (rx_valid) begin
            rx_valid_cnt++;
            last_rx = rx_data;
            cg_rx_i.sample();
            if (!sweep_mode) begin
                if (rx_exp.size() == 0)
                    check(0, $sformatf("RX unexpected byte %02h", rx_data));
                else begin
                    rx_e = rx_exp.pop_front();
                    check(rx_data === rx_e, $sformatf("RX byte %02h, expected %02h", rx_data, rx_e));
                end
            end
        end
        if (rx_frame_err) rx_ferr_cnt++;
    end

    // ---- Helper tasks -------------------------------------------------------
    task automatic do_reset(int cycles = 4);
        @(negedge clk);
        rst_n = 0; tx_start = 0;
        repeat (cycles) @(negedge clk);
        tx_exp.delete(); rx_exp.delete();
        exp_ferr = 0; rx_valid_cnt = 0; rx_ferr_cnt = 0;
        rst_n = 1;
    endtask

    task automatic wait_clks(int k);
        repeat (k) @(negedge clk);
    endtask

    task automatic settle(int bits = 2);    // let in-flight frames finish
        wait_clks(bits * n + 8);
    endtask

    task automatic set_n(int v);            // only change N while both are idle
        @(negedge clk iff !tx_busy);
        n = v;
    endtask

    task automatic expect_empty(string tag);
        check(tx_exp.size() == 0, $sformatf("%s: %0d TX frame(s) never sent", tag, tx_exp.size()));
        check(rx_exp.size() == 0, $sformatf("%s: %0d RX byte(s) never received", tag, rx_exp.size()));
        check(rx_ferr_cnt == exp_ferr,
              $sformatf("%s: %0d frame errors, expected %0d", tag, rx_ferr_cnt, exp_ferr));
    endtask

    // Send one byte through uart_tx (one-clock tx_start pulse)
    task automatic tx_send(logic [7:0] d);
        @(negedge clk iff !tx_busy);
        tx_data = d; tx_start = 1;
        tx_exp.push_back(d);
        if (loop_en) rx_exp.push_back(d);
        @(negedge clk);
        tx_start = 0;
    endtask

    task automatic tx_wait_done();
        @(negedge clk iff tx_done);
    endtask

    // Bit-bang one frame onto rx. err_pct = sender baud error (+ = slower).
    // align=1: start at a random point inside a clock period (async input).
    task automatic rx_send(logic [7:0] d, real err_pct = 0.0, bit stop = 1,
                           bit expect_it = 1, bit align = 1);
        real bt = n * CLK_NS * (1.0 + err_pct / 100.0);
        if (align) begin
            @(posedge clk);
            #($urandom_range(1, int'(CLK_NS) - 1));
        end
        if (expect_it) begin
            if (stop) rx_exp.push_back(d);
            else      exp_ferr++;
        end
        rx_drv = 0;            #(bt);       // start
        for (int i = 0; i < 8; i++) begin
            rx_drv = d[i];     #(bt);       // data, LSB first
        end
        rx_drv = stop;         #(bt);       // stop
        rx_drv = 1;
    endtask

    // A low pulse of exactly len clock periods, at a random phase
    task automatic rx_glitch(int len);
        @(posedge clk);
        #($urandom_range(1, int'(CLK_NS) - 1));
        rx_drv = 0;
        #(len * CLK_NS);
        rx_drv = 1;
    endtask

    // =========================================================================
    // Tests
    // =========================================================================

    // A. Reset and idle
    task automatic test_reset();
        $display("--- A. reset / idle");
        rst_n = 0;
        wait_clks(5);
        check(tx === 1 && tx_busy === 0 && tx_done === 0 && rx_valid === 0 && rx_frame_err === 0,
              "outputs during reset");
        rst_n = 1;
        wait_clks(30 * n);                  // 3 frame-times of idle
        check(rx_valid_cnt == 0 && rx_ferr_cnt == 0 && tx_frames == 0,
              "reset release must not start a frame");
        hit(E_RST_IDLE);
    endtask

    // B. TX on its own (monitor checks the pin)
    task automatic test_tx_basic();
        int ns[] = '{8, 9, 16, 17, 174};
        $display("--- B. TX patterns, N = 8/9/16/17/174");
        foreach (ns[i]) begin
            set_n(ns[i]);
            foreach (patterns[p]) begin tx_send(patterns[p]); tx_wait_done(); end
            repeat (8) begin tx_send($urandom); tx_wait_done(); end
            settle();
            expect_empty($sformatf("TX basic N=%0d", ns[i]));
        end
    endtask

    task automatic test_tx_latch();
        $display("--- B. TX latches tx_data at start");
        set_n(16);
        tx_send(8'hA5);
        wait_clks(3 * n);
        tx_data = 8'h5A;                    // change mid-frame: must not matter
        tx_wait_done();
        settle();
        expect_empty("TX latch");
        hit(E_TX_LATCH);
    endtask

    task automatic test_tx_start_busy();
        $display("--- B. TX ignores tx_start while busy");
        set_n(16);
        tx_send(8'h3C);
        wait_clks(4 * n);
        tx_data = 8'hC3; tx_start = 1;      // try to start again mid-frame
        @(negedge clk); tx_start = 0;
        tx_wait_done();
        settle(12);                         // long enough to see a wrong 2nd frame
        check(!tx_busy, "TX restarted from a tx_start seen while busy");
        expect_empty("TX start-while-busy");
        hit(E_TX_START_BUSY);
    endtask

    task automatic test_tx_b2b();
        logic [7:0] d;
        $display("--- B. TX back-to-back (tx_start held high)");
        set_n(8);
        d = $urandom; tx_data = d; tx_start = 1; tx_exp.push_back(d);
        for (int k = 1; k <= 5; k++) begin
            @(negedge clk iff tx_done);
            if (k < 5) begin
                d = $urandom; tx_data = d; tx_exp.push_back(d);
                @(negedge clk);
                check(tx === 0 && tx_busy === 1, "back-to-back: next start after exactly 1 idle clock");
            end else
                tx_start = 0;
        end
        settle();
        expect_empty("TX back-to-back");
        hit(E_TX_B2B);
    endtask

    task automatic test_tx_reset_mid();
        $display("--- B. TX reset mid-frame");
        set_n(16);
        tx_send(8'h96);
        wait_clks(4 * n);
        do_reset();
        @(negedge clk);
        check(tx === 1 && tx_busy === 0, "TX idle after reset mid-frame");
        tx_send(8'h69); tx_wait_done();     // and it recovers
        settle();
        expect_empty("TX reset mid-frame");
        hit(E_TX_RST_MID);
    endtask

    // C. RX on its own (driver bit-bangs the line)
    task automatic test_rx_basic();
        int ns[] = '{8, 9, 16, 17, 174};
        $display("--- C. RX patterns, N = 8/9/16/17/174");
        foreach (ns[i]) begin
            set_n(ns[i]);
            foreach (patterns[p]) begin rx_send(patterns[p]); settle(1); end
            for (int r = 0; r < 8; r++) begin                // one byte per value region
                rx_send({r[2:0], 5'($urandom)}); settle(1);
            end
            settle();
            expect_empty($sformatf("RX basic N=%0d", ns[i]));
        end
    endtask

    task automatic test_rx_b2b();
        $display("--- C. RX back-to-back, no idle");
        set_n(16);
        rx_send($urandom);
        repeat (7) rx_send($urandom, 0.0, 1, 1, 0);         // align=0: no gap
        settle();
        expect_empty("RX back-to-back");
        hit(E_RX_B2B);
    endtask

    task automatic test_rx_glitch();
        int ns[] = '{8, 16, 17, 174};
        int before_v, before_e, thr;
        $display("--- C. RX glitch rejection + threshold");
        foreach (ns[i]) begin
            set_n(ns[i]);
            // RX checks the line at ½ bit (minus sync latency). Working it out from
            // the RTL: a low pulse of L clocks is rejected when L <= (N>>1) - 2.
            thr = (n >> 1) - 2;
            before_v = rx_valid_cnt; before_e = rx_ferr_cnt;
            for (int len = 1; len <= thr; len++) begin
                rx_glitch(len);
                wait_clks((n >> 1) + 6);    // RX is back in IDLE by now
            end
            settle(11);
            check(rx_valid_cnt == before_v && rx_ferr_cnt == before_e,
                  $sformatf("N=%0d: a glitch of <= %0d clocks was taken as a start bit", n, thr));
            hit(E_GLITCH_REJ);
            // One clock longer: accepted as a start bit, the line is then high
            // for every data bit and the stop bit, so RX must deliver 0xFF.
            rx_exp.push_back(8'hFF);
            rx_glitch(thr + 1);
            settle(11);
            expect_empty($sformatf("RX glitch threshold N=%0d", n));
            hit(E_GLITCH_EDGE_ACC);
        end
    endtask

    task automatic test_rx_frame_err();
        int ns[] = '{8, 16, 174};
        $display("--- C. RX frame error (stop bit = 0)");
        foreach (ns[i]) begin
            set_n(ns[i]);
            rx_send(8'h5A, 0.0, 0);         // bad stop bit
            settle();
            rx_send(8'hA5);                 // next good frame still works
            settle();
            expect_empty($sformatf("RX frame error N=%0d", n));
        end
        hit(E_FRAME_ERR);
    endtask

    task automatic test_rx_hold();
        $display("--- C. RX holds rx_data (overrun window)");
        set_n(16);
        rx_send(8'h11); settle(1);
        fork
            rx_send(8'h22);
            begin
                wait_clks(5 * n);           // halfway through the next frame
                check(rx_data === 8'h11, "rx_data must hold the old byte during the next frame");
            end
        join
        settle(1);
        check(rx_data === 8'h22, "rx_data updated to the new byte");
        rx_send(8'h33, 0.0, 0);             // a bad frame must not overwrite it
        settle();
        check(rx_data === 8'h22, "rx_data unchanged after a frame error");
        expect_empty("RX hold");
        hit(E_RX_HOLD);
    endtask

    task automatic test_rx_reset_mid();
        $display("--- C. RX reset mid-frame");
        set_n(16);
        fork
            rx_send(8'h00, 0.0, 1, 0);      // not expected: it gets cut off
        join_none
        wait_clks(4 * n);                   // RX is in DATA now
        disable fork;
        rx_drv = 1;
        do_reset();
        settle(12);
        check(rx_valid_cnt == 0 && rx_ferr_cnt == 0, "no output from a frame cut by reset");
        rx_send(8'hC7); settle();           // and it recovers
        expect_empty("RX reset mid-frame");
        hit(E_RX_RST_MID);
    endtask

    // D. Changing N between frames, and baud tolerance
    task automatic test_n_change();
        int ns[] = '{8, 16, 9, 174, 17, 8};
        $display("--- D. N changed between frames");
        foreach (ns[i]) begin
            set_n(ns[i]);
            rx_send($urandom); settle(1);
            tx_send($urandom); tx_wait_done();
        end
        settle();
        expect_empty("N change");
        hit(E_N_CHANGE);
    endtask

    task automatic test_baud_sweep();
        int  ns[]  = '{16, 174};
        real errs[] = '{-10.0, -8.0, -6.0, -5.0, -4.0, -3.0, -2.0, -1.0, 0.0,
                          1.0,  2.0,  3.0,  4.0,  5.0,  6.0,  8.0, 10.0};
        logic [7:0] bytes[] = '{8'h55, 8'hAA, 8'h00, 8'hFF, 8'h96};
        bit ok;
        $display("--- D. baud tolerance sweep (sender error vs RX)");
        sweep_mode = 1;
        foreach (ns[i]) begin
            set_n(ns[i]);
            foreach (errs[e]) begin
                ok = 1;
                foreach (bytes[b]) begin
                    do_reset();
                    rx_send(bytes[b], errs[e], 1, 0);
                    settle(12);
                    if (!(rx_valid_cnt == 1 && last_rx === bytes[b] && rx_ferr_cnt == 0)) ok = 0;
                end
                $display("    N=%4d  error %5.1f%%  -> %s", n, errs[e], ok ? "ok" : "FAIL");
                if (errs[e] >= -3.0 && errs[e] <= 3.0)
                    check(ok, $sformatf("N=%0d: %0.1f%% baud error must still work", n, errs[e]));
                if (ok && errs[e] < 0) hit(E_BAUD_FAST_OK);
                if (ok && errs[e] > 0) hit(E_BAUD_SLOW_OK);
                if (!ok)               hit(E_BAUD_FAIL);
            end
        end
        sweep_mode = 0;
        do_reset();
    endtask

    // E. Loopback: tx -> rx, all 256 values + every N bin
    task automatic test_loopback();
        int ns_all[] = '{8, 16};
        int ns_reg[] = '{9, 17, 174, 4095};
        $display("--- E. loopback TX -> RX");
        loop_en = 1;
        foreach (ns_all[i]) begin
            set_n(ns_all[i]);
            for (int v = 0; v < 256; v++) begin tx_send(v); tx_wait_done(); end
            settle();
            expect_empty($sformatf("loopback all values N=%0d", n));
        end
        foreach (ns_reg[i]) begin
            set_n(ns_reg[i]);
            for (int r = 0; r < 8; r++) begin tx_send({r[2:0], 5'($urandom)}); tx_wait_done(); end
            settle();
            expect_empty($sformatf("loopback N=%0d", n));
        end
        loop_en = 0;
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin : main
        $display("=== tb_uart  clk=%0.0f MHz", 1000.0 / CLK_NS);

        test_reset();
        test_tx_basic();
        test_tx_latch();
        test_tx_start_busy();
        test_tx_b2b();
        test_tx_reset_mid();
        test_rx_basic();
        test_rx_b2b();
        test_rx_glitch();
        test_rx_frame_err();
        test_rx_hold();
        test_rx_reset_mid();
        test_n_change();
        test_baud_sweep();
        test_loopback();

        $display("=== Coverage: RX %0.1f%%  TX %0.1f%%  scenarios %0.1f%%",
                 cg_rx_i.get_inst_coverage(), cg_tx_i.get_inst_coverage(),
                 cg_evt_i.get_inst_coverage());
        $display("=== %0d checks, %0d errors, %0d TX frames monitored", checks, errors, tx_frames);
        if (errors == 0) $display("=== TEST PASSED");
        else             $display("=== TEST FAILED");
        $finish;
    end

    // Watchdog: a hung test must not run forever
    initial begin
        #(500_000_000);                     // 500 ms of sim time
        $fatal(1, "TIMEOUT: testbench hung");
    end

endmodule
