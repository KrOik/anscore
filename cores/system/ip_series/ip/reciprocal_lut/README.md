# gw2a_ips_reciprocal_lut

12-bit reciprocal ROM with one Newton-Raphson refinement step and exact division check flag

- Series: `ips` (ip_series_20k), family `arith`.
- Core RTL: `src/ips_reciprocal_lut.v`; testbench `sim/tb_ips_reciprocal_lut.v`; independent golden model `models/ips_reciprocal_lut.py`.
- Packaged wrapper: `gw2a_ips_reciprocal_lut.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `CC64EF88` == golden model digest `CC64EF88`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 272 LUT-class, 1 DSP-class (budget 340 / 1).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
