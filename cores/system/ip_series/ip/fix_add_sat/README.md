# gw2a_ips_fix_add_sat

Pipelined fixed-point add/sub with saturating or wrap-around result and sticky saturation flag

- Series: `ips` (ip_series_20k), family `arith`.
- Core RTL: `src/ips_fix_add_sat.v`; testbench `sim/tb_ips_fix_add_sat.v`; independent golden model `models/ips_fix_add_sat.py`.
- Packaged wrapper: `gw2a_ips_fix_add_sat.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `423D34A5` == golden model digest `423D34A5`; 5 literal mutants all detected (2 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 164 LUT-class, 0 DSP-class (budget 300 / 1).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
