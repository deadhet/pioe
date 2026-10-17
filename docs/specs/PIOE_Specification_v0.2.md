# PIOE — Programmable Protocol Converter Chip: Specification v0.2

> **Status:** Draft, in progress · **Target:** Tiny Tapeout, SKY130 · Supersedes `PIOE_Specification_v0.1.pdf` section by section as each one is revised.

## Changes since v0.1 (running list)
- Architecture fixed: **programmable ISA engine**. The per-protocol FSMs are reference models used to derive the ISA.
- PDK: **SKY130** (IHP port for the Jane Street competition kept as an option).
- v1 scope: UART TX+RX, SPI master, I2C master.
- **New §C — Clock & run-time timing (divisor N).**
- *Pending:* pin map / TT I/O realities (rst_n as boot trigger, open-drain only on `uio`), ISA, boot flow update.

---

## §C. Clock & Run-time Timing (divisor N)

### C.1 Where the clock comes from
- PIOE **does not generate a clock**. It runs on the single `clk` input supplied by the board it is mounted on (e.g. the Tiny Tapeout demo PCB, or the user's own board).
- The chip's designers do **not** know or fix the final clock frequency. The **user** chooses it when they build the system.
- The silicon only guarantees a **maximum** `f_clk`: whatever the design meets in timing analysis (v1 target 20 MHz, stretch goal 50 MHz).

### C.2 The divisor N
- All protocol timing (UART bit time, SPI SCK period, I2C SCL period) comes from **counting `clk` cycles**:

  ```
  N = round( f_clk / f_target )        e.g. UART: f_target = baud rate
  ```

- **N is a run-time parameter.** It is chosen by the **user** from **their** clock and **their** desired protocol speed, and written into the PIOE program in the external flash.
- **N will be carried in the ISA.** Exactly how is decided during ISA design, e.g. a delay field inside instructions, a `DELAY n` instruction, or a clock-divider value loaded at boot.
- Same silicon, different clock → only N in the program changes. The chip is never redesigned.

### C.3 What is fixed in silicon (design-time)
| Decision | Effect |
|---|---|
| Counter width for N | Sets the **slowest** supported speed (longest bit time) |
| Minimum cycles per bit | Sets the **fastest** supported speed (the engine needs a few cycles per bit to act) |
| Max `f_clk` (from STA) | Sets the upper limit on everything |

Counter width is a trade-off between **range** and **area** (each extra bit is about one more flip-flop plus adder logic). It is still open and will be finalised from the protocol requirements.

**Minimum N (UART).** For UART: **N ≥ 8 minimum, N ≥ 16 recommended**, and the rounding error |N − f_clk/baud| / (f_clk/baud) must be ≤ 2%. This is **documented, not enforced**: the hardware does not clamp N, and behaviour below the minimum is undefined. The reasons are synchronizer latency, ±1-clock edge uncertainty and integer rounding (details in `protocols/uart_rx.md` §R.8a). SPI/I2C minimums are added when those specs are written.

### C.4 Reference calculations (assume f_clk = 20 MHz)
These are **examples** for design and verification only. Real users recompute them for their own clock.

| Protocol | Target speed | N = 20 MHz / target | Actual | Error |
|---|---|---|---|---|
| UART | 9600 baud | 2083 | 9601.5 baud | +0.02% |
| UART | 115200 baud | 174 | 114942.5 baud | −0.22% |
| UART | 1 Mbaud | 20 | 1 Mbaud | 0.00% |
| SPI / I2C | *(added when those specs are written)* | | | |

Counter width needed for these examples (16 bits gives 305 baud):
| Width | Max N | Slowest UART at 20 MHz |
|---|---|---|
| 8 bits | 255 | ≈ 78 kbaud (9600 not possible) |
| 12 bits | 4095 | ≈ 4.9 kbaud |
| 16 bits | 65535 | ≈ 305 baud |

### C.5 Summary (interview line)
> *"The baud rate is a run-time parameter: the user sets divisor N in the program based on their board clock. The counter width is a design-time decision that fixes the range of speeds the chip can support."*
