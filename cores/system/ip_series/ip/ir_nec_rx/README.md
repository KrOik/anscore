# gw2a_ips_ir_nec_rx

NEC infrared receiver: leader/carrier timing validator, 32-bit frame with repeat code and command CRC

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_ir_nec_rx.v`; testbench `sim/tb_ips_ir_nec_rx.v`; independent golden model `models/ips_ir_nec_rx.py`.
- Packaged wrapper: `gw2a_ips_ir_nec_rx.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `57363727` == golden model digest `57363727`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 126 LUT-class, 0 DSP-class (budget 280 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
