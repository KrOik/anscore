# gw2a_ips_err_log_sticky

First-N error capture with timestamp, source code and overflow-protected ring log

- Series: `ips` (ip_series_20k), family `obs`.
- Core RTL: `src/ips_err_log_sticky.v`; testbench `sim/tb_ips_err_log_sticky.v`; independent golden model `models/ips_err_log_sticky.py`.
- Packaged wrapper: `gw2a_ips_err_log_sticky.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `D9005D70` == golden model digest `D9005D70`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 196 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
