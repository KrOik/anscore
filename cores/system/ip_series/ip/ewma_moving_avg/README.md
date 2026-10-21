# gw2a_ips_ewma_moving_avg

Alpha-weighted EWMA plus N-tap circular moving average with warm-up correctness

- Series: `ips` (ip_series_20k), family `arith`.
- Core RTL: `src/ips_ewma_moving_avg.v`; testbench `sim/tb_ips_ewma_moving_avg.v`; independent golden model `models/ips_ewma_moving_avg.py`.
- Packaged wrapper: `gw2a_ips_ewma_moving_avg.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `EC83A4F3` == golden model digest `EC83A4F3`; 6 literal mutants all detected (4 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 253 LUT-class, 0 DSP-class (budget 300 / 1).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
