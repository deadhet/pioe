# PIOE — Programmable I/O Engine (Protocol Converter Chip)

A small, firmware-programmable chip that converts between **UART, SPI and I2C** in any direction. A tiny ISA program sits in an external SPI flash; at reset the chip boots by copying it into internal instruction slots, then runs standalone.

**Target:** Tiny Tapeout (SKY130) · **Status:** Specification phase

## Repository layout
| Path | Contents |
|---|---|
| `docs/specs/` | Chip specification (versioned) |
| `docs/specs/protocols/` | Per-protocol specs: UART, SPI, I2C (signals, timing, FSMs) |
| `docs/architecture/` | Block diagrams, ISA definition, design decisions |
| `programs/` | Example PIOE programs (flash images) |
| `src/` | RTL (Verilog) |
| `test/` | SystemVerilog testbenches |

## Roadmap (v1)
- [ ] Spec v0.2 (architecture, pin map, ISA draft)
- [ ] Protocol specs: UART, SPI master, I2C master
- [ ] RTL + SV testbenches per block
- [ ] Sequencer / ISA engine + SPI-flash bootloader
- [ ] Synthesis, area check, RTL→GDS hardening
- [ ] FPGA bring-up
- [ ] Tiny Tapeout submission
