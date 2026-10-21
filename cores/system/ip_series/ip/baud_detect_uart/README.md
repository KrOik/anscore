# gw2a_ips_baud_detect_uart

UART receive-side baud estimator measuring the 0-bit run length and deriving an integer oversample tick

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_baud_detect_uart.v`; testbench `sim/tb_ips_baud_detect_uart.v`; independent golden model `models/ips_baud_detect_uart.py`.
- Packaged wrapper: `gw2a_ips_baud_detect_uart.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `FCB987E1` == golden model digest `FCB987E1`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 140 LUT-class, 0 DSP-class (budget 240 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
