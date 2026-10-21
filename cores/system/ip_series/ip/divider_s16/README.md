# gw2a_ips_divider_s16

Iterative restoring signed 16/16 fixed-point divide, quotient plus remainder and divide-by-zero flag

- Series: `ips` (ip_series_20k), family `arith`.
- Core RTL: `src/ips_divider_s16.v`; testbench `sim/tb_ips_divider_s16.v`; independent golden model `models/ips_divider_s16.py`.
- Packaged wrapper: `gw2a_ips_divider_s16.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `2C395678` == golden model digest `2C395678`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 228 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
