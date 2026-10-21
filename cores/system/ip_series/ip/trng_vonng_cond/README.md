# gw2a_ips_trng_vonng_cond

Ring-oscillator entropy source collector with von Neumann conditioning and continuous health tests

- Series: `ips` (ip_series_20k), family `sec`.
- Core RTL: `src/ips_trng_vonng_cond.v`; testbench `sim/tb_ips_trng_vonng_cond.v`; independent golden model `models/ips_trng_vonng_cond.py`.
- Packaged wrapper: `gw2a_ips_trng_vonng_cond.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `F1D45136` == golden model digest `F1D45136`; 6 literal mutants all detected (4 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 103 LUT-class, 0 DSP-class (budget 300 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
