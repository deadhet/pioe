# Running the UART testbenches and viewing waveforms

This folder holds the testbenches for the PIOE UART:

| Testbench | What it tests | Partner it is checked against |
|---|---|---|
| `tb_uart_tx.sv` | `uart_tx` on its own | Pin checker (every clock) + reference receiver `ref/ref_uart_rx.v` |
| `tb_uart_rx.sv` | `uart_rx` on its own: bytes, glitches, baud error, X/Z, several senders at once | Reference transmitter `ref/ref_uart_tx.v` + 3 TB line drivers + pull-up |
| `tb_uart.sv` | TX → RX loopback (system test) | Its own monitor/driver + scoreboard |

Every testbench prints a log ending in `TEST PASSED` or `TEST FAILED`, plus its
functional coverage. You never have to read waveforms to know whether it passed.
Waveforms are for **understanding** what happens, and for **debugging** when a check fails.

There are three ways to run them:

- **A. Vivado GUI.** Easiest. Run and look at the waveforms in one place.
- **B. One command, no GUI.** Quick pass/fail. It also saves a waveform file you can open later.
- **C. xsim on the command line.** Most control, for example saving the waveform of just one test.

---

## 0. Every time: mount the SSD and set up the terminal

```bash
ssd-mount                                                   # needs your sudo password
source /mnt/linux-vivado/Xilinx/2026.1/Vivado/settings64.sh # puts vivado/xsim on PATH
```

The `source` line only lasts for that terminal window, so run it again in each new terminal.

If the project is missing or broken, rebuild it. This never touches the `.v`/`.sv` files:

```bash
cd ~/Claude/PIOE
vivado -mode batch -source pioe/scripts/vivado_uart.tcl
```

---

## A. Vivado GUI

### A1. Open the project

```bash
cd ~/Claude/PIOE/vivado/uart
vivado uart.xpr &
```

### A2. Choose which testbench to run

The project has three **simulation sets**, one per testbench:

| Simulation set | Top module |
|---|---|
| `sim_1` | `tb_uart` (loopback) |
| `sim_tx` | `tb_uart_tx` |
| `sim_rx` | `tb_uart_rx` |

1. In the **Sources** panel, open **Simulation Sources**.
2. Right-click the set you want, e.g. **sim_rx**, and choose **Make Active**. The active set is shown in bold.

### A3. Run

1. In the **Flow Navigator** on the left, go to **SIMULATION → Run Simulation → Run Behavioral Simulation**.
2. Vivado compiles, elaborates and runs **to the end** (`$finish`). It takes about 10–60 s.
3. The **Tcl Console** at the bottom shows the log. Scroll to the end for `TEST PASSED` and the coverage numbers.
4. Each test section's header line shows the time it started, e.g.
   `--- 13. X on the rx line   [t = 76588900 ns]`. You'll use these times to find things in the waveform.

### A4. Look at the waveform

When the run finishes, a **waveform window** opens. At first it shows only the testbench's top-level signals.

**Add more signals:**

1. In the **Scope** panel, click a level of the design:
   - `tb_uart_rx` for the testbench signals.
   - `dut` for signals inside your RTL, e.g. `state`, `baud_cnt`, `bit_cnt`, `rx_sync`, `rx_reg`.
   - `ref_tx` / `ref_rx` for the reference UART.
2. The **Objects** panel lists that level's signals. Drag them into the waveform window, or right-click → **Add to Wave Window**.

The project records **every** signal from time 0 (`log_all_signals` is on), so a signal you add later already has its whole history. No re-run is needed.

**Move around:**

| Want to | Do |
|---|---|
| See the whole run | **Zoom Fit** button in the waveform toolbar |
| Zoom in / out | **Ctrl + mouse wheel** (zooms around the mouse), or the + / − buttons |
| Measure a time | Click to place the cursor; add a **marker** (toolbar) and click again; the time difference is shown |
| Find the next change of a signal | Select the signal, then use **Next Transition** in the toolbar |

**Make values readable:**

- Right-click a bus (e.g. `rx_data`) → **Radix → Hexadecimal**.
- `state` is shown as a number. The mapping is the same in TX and RX:

  | Value | State |
  |---|---|
  | 0 | IDLE |
  | 1 | START |
  | 2 | DATA |
  | 3 | STOP |

- Unknown values are drawn in red: **X** is red, **Z** is often shown as a line in the middle. They appear on purpose in the RX X/Z and collision tests.

**Save your signal list** so you don't have to drag everything in again next time: **File → Simulation Waveform → Save Configuration As…** → e.g. `rx_view.wcfg`. Next time, open it with **File → Simulation Waveform → Open Configuration**.

### A5. Re-run after editing code

Click **Relaunch Simulation** (circular arrow in the simulation toolbar). It recompiles the changed files and runs again. Your waveform signals stay in place.

### A6. Run only part of the simulation (optional)

The full run is long (around 60–77 ms of simulated time, millions of clocks). To step through it yourself, type in the **Tcl Console**:

```tcl
restart              ;# back to time 0
run 2 us             ;# just the reset
run 1 ms             ;# the first test sections
run 76588900 ns      ;# from where you are now, run on by this much
run all              ;# to the end
```

Note that `run <time>` runs **for** that long, counting from where you are now.

---

## B. One command, no GUI

```bash
cd ~/Claude/PIOE
vivado -mode batch -source pioe/scripts/vivado_uart.tcl -tclargs sim       # all three testbenches
vivado -mode batch -source pioe/scripts/vivado_uart.tcl -tclargs sim_rx    # only tb_uart_rx
vivado -mode batch -source pioe/scripts/vivado_uart.tcl -tclargs sim_tx    # only tb_uart_tx
```

The log is printed in the terminal. Look for `TEST PASSED`.

Each run also saves a **waveform file** (`.wdb`, about 50 MB each):

```
~/Claude/PIOE/vivado/uart/uart.sim/sim_tx/behav/xsim/tb_uart_tx_behav.wdb
~/Claude/PIOE/vivado/uart/uart.sim/sim_rx/behav/xsim/tb_uart_rx_behav.wdb
~/Claude/PIOE/vivado/uart/uart.sim/sim_1/behav/xsim/tb_uart_behav.wdb
```

To open one without re-running:

```bash
cd ~/Claude/PIOE/vivado/uart/uart.sim/sim_rx/behav/xsim
xsim --gui tb_uart_rx_behav.wdb &
```

Then add signals and move around exactly as in A4.

---

## C. xsim on the command line (the steps Vivado does for you)

Vivado's simulator runs in three steps. This is the same idea as for every Verilog simulator:

| Step | Tool | What it does |
|---|---|---|
| 1. Compile | `xvlog` | Checks each file's syntax and turns it into a library of compiled modules |
| 2. Elaborate | `xelab` | Starts at the top module, builds the whole hierarchy, connects the ports, makes a runnable *snapshot* |
| 3. Simulate | `xsim` | Runs the snapshot |

Use a work folder **outside the git repo**, because the tools leave many files behind:

```bash
mkdir -p ~/Claude/PIOE/vivado/xsim_run
cd ~/Claude/PIOE/vivado/xsim_run
P=~/Claude/PIOE/pioe
```

### C1. Compile

```bash
xvlog $P/src/uart_tx.v $P/src/uart_rx.v $P/test/ref/ref_uart_tx.v $P/test/ref/ref_uart_rx.v
xvlog -sv $P/test/tb_uart_tx.sv $P/test/tb_uart_rx.sv $P/test/tb_uart.sv
```

`-sv` means "these files are SystemVerilog". The plain `.v` files are Verilog.

### C2. Elaborate (one snapshot per testbench)

```bash
xelab tb_uart_tx -debug typical -s tx_sim
xelab tb_uart_rx -debug typical -s rx_sim
xelab tb_uart    -debug typical -s loop_sim
```

`-debug typical` keeps signal names, so you can see waveforms. Without it the run is a little faster, but there's nothing to look at. `-s` names the snapshot.

### C3a. Run, text only

```bash
xsim tx_sim -R                 # -R = run to the end, then exit
xsim rx_sim -R -sv_seed 42     # different random bytes / edge timing
```

### C3b. Run and save the waveform of everything

```bash
printf 'log_wave -recursive *\nrun all\nquit\n' > waves_all.tcl
xsim rx_sim -tclbatch waves_all.tcl -wdb rx_all.wdb
xsim --gui rx_all.wdb &
```

`log_wave -recursive *` means "record every signal at every level".

### C3c. Save the waveform of ONE test only (small file, easy to view)

Take the start time from the log (e.g. `--- 13. X on the rx line [t = 76588900 ns]`). Run *without* recording up to that point, then record a window:

```bash
printf 'run 76588900 ns\nlog_wave -recursive *\nrun 400 us\nquit\n' > waves_xz.tcl
xsim rx_sim -tclbatch waves_xz.tcl -wdb rx_xz.wdb
xsim --gui rx_xz.wdb &
```

This file is only about 0.2 MB. **Zoom Fit** then shows just that window: the X/Z tests, the open-drain tests and the start of the simultaneous-sender tests.

### C3d. Interactive GUI on a snapshot

```bash
xsim rx_sim -gui &
```

Then, in its Tcl console:

```tcl
log_wave -recursive *
run 77 ms
```

---

## D. Where to look: start times of each test

These times come from the default seed. A different `-sv_seed` shifts them slightly.

### `tb_uart_rx` (rx line + RX internals)

| Time | Test | Signals worth watching |
|---|---|---|
| 0 | 1. reset | `rst_n`, `rx_line`, `dut/state` |
| 24.25 µs | 2. all 256 bytes from reference TX, N=8 | `ref_txd`, `rx_line`, `rx_valid`, `rx_data` (hex) |
| 28.96 ms | 4. TB driver patterns (N=8 … 4095) | `driver[0]`, `rx_line`, `dut/rx_sync`, `dut/baud_cnt`, `dut/bit_cnt` |
| 61.32 ms | 5. back-to-back frames | `rx_line`, `dut/state` (no IDLE gap) |
| 61.42 ms | 6. glitch rejection | `rx_line`, `dut/state` (1 → 0 = START → IDLE: glitch rejected) |
| 62.63 ms | 7. frame error | `rx_frame_err` pulse |
| 62.87 ms | 8. break (line stuck low) | one `rx_frame_err`, then quiet |
| 62.95 ms | 10. reset in every state | `rst_n`, `dut/state` |
| 65.68 ms | 12. baud error sweep | `rx_line` vs `dut/baud_cnt` (sample point drifting) |
| **76.59 ms** | **13. X on the line** | `rx_line` (red X), `dut/rx_meta`, `dut/rx_sync`, `dut/state` stays known |
| **76.74 ms** | **13. Z on the line** | `pullup_on`, `rx_line` (Z), `rx_data` bit 3 unknown |
| 76.89 ms | 14. sender lets go mid-frame | `driver[0]` → Z, with/without `pullup_on` |
| 76.95 ms | 15. open-drain + pull-up (wired-AND) | `driver[0]`, `driver[1]`, `rx_line` = AND |
| **76.97 ms** | **16. 2 / 3 senders at the same time** | `driver[0..2]`, `rx_line` (X where they disagree), `rx_data` |
| **77.08 ms** | **17. late sender while RX is in START / DATA / STOP** | `driver[*]`, `rx_line`, `dut/state` |

### `tb_uart_tx` (tx pin + TX internals)

| Time | Test | Signals worth watching |
|---|---|---|
| 0 | 1. reset | `rst_n`, `tx`, `tx_busy` |
| 24.25 µs | 2. reset + tx_start together | `rst_n`, `tx_start`, `tx` stays 1 |
| 40.45 µs | 3. all 256 bytes, N=8 | `tx_start`, `tx`, `tx_done`, `ref_valid`, `ref_data` |
| 3.37 ms | 4. N=24 patterns | `tx`, `dut/baud_cnt` (0…23), `dut/bit_cnt` |
| 55.78 ms | 5. back-to-back | `tx_done` → next start bit exactly 1 clock later |
| 55.83 ms | 6. tx_start / tx_data poked while busy | `tx_start`, `tx_data`, `dut/state`, `tx` unchanged |
| 56.01 ms | 8. reset in every state | `rst_n`, `dut/state` |
| 58.24 ms | 10. X / Z on inputs | `tx_start` (X, Z), `tx_data`, `tx` (X/Z bits) |

---

## E. What one frame looks like (N = 8)

```
clock:    |0 ......... 8 ......... 16 ... 72 ......... 80
tx:  ‾‾‾‾‾|___start____|== bit0 ==|...|== bit7 ==|‾‾‾stop‾‾‾|‾‾‾‾
state:  0 |     1      |    2     |...|    2     |     3     | 0
tx_busy:__|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|____
tx_done:___________________________________________________|‾|__   (1 clock)
```

- Every bit is exactly **N clocks**, and a frame is exactly **10 × N clocks**.
- Data goes out **LSB first** (bit 0 right after the start bit).
- On the RX side, `rx_valid` comes in the **middle of the stop bit**, about 9.5 bits after the falling edge. That's where RX checks the stop bit.

---

## F. Verilator (fast pass/fail, no X/Z)

Verilator is a 2-state simulator: it has no X or Z. So it can run `tb_uart_tx.sv` and `tb_uart.sv`, but **not** `tb_uart_rx.sv`, which needs X, Z and several drivers on one wire. Use xsim for waveforms.

```bash
mkdir -p ~/Claude/PIOE/sim/verilator && cd ~/Claude/PIOE/sim/verilator
P=~/Claude/PIOE/pioe
verilator --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style -Wno-ZERODLY -Wno-TIMESCALEMOD \
  --top-module tb_uart_tx -Mdir obj_tx -j 8 \
  $P/test/tb_uart_tx.sv $P/src/uart_tx.v $P/test/ref/ref_uart_rx.v
./obj_tx/Vtb_uart_tx
```

---

## G. When a test fails

1. Find the **first** `ERROR at <time>: …` line in the log. Later errors are often just knock-on effects of the first.
2. Open the waveform and go to that time. Use C3c to record a small window that starts a little before it.
3. Add `dut/state`, the counters, and the inputs/outputs named in the error message.
4. Ask yourself: *in which state was the FSM, what did it see, and what did it do on that clock edge?*
