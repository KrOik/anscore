# gw2a_ips_isqrt_iter

Digit-by-digit integer square root, 16 iterations, returns root and residual

- Series: `ips` (ip_series_20k), family `arith`.
- Core RTL: `src/ips_isqrt_iter.v`; testbench `sim/tb_ips_isqrt_iter.v`; independent golden model `models/ips_isqrt_iter.py`.
- Packaged wrapper: `gw2a_ips_isqrt_iter.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `A4F6B599` == golden model digest `A4F6B599`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 162 LUT-class, 0 DSP-class (budget 220 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
