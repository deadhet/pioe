# Reference UART (third-party, MIT)

Independent UART used as a "golden" partner in the PIOE testbenches:
- `ref_uart_rx` receives what PIOE `uart_tx` sends (`test/tb_uart_tx.sv`)
- `ref_uart_tx` sends what PIOE `uart_rx` receives (`test/tb_uart_rx.sv`)

Source: https://github.com/alexforencich/verilog-uart, commit `1b867e5` (2025-02-27), files `rtl/uart_tx.v`, `rtl/uart_rx.v`.
License: MIT, see `LICENSE_verilog-uart.txt`. The only change is the module rename (`uart_*` → `ref_uart_*`).

Note: its bit time is `prescale * 8` clocks, so it can only be paired with PIOE when N is a multiple of 8.
Other N values are checked by the testbenches' own pin checker / line driver.
