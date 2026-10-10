# gw2a_ips_rr_arbiter4

Four-master round-robin arbiter with lock-on-grant, starvation counter and lock-step fairness

- Series: `ips` (ip_series_20k), family `ctrl`.
- Core RTL: `src/ips_rr_arbiter4.v`; testbench `sim/tb_ips_rr_arbiter4.v`; independent golden model `models/ips_rr_arbiter4.py`.
- Packaged wrapper: `gw2a_ips_rr_arbiter4.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `19346C20` == golden model digest `19346C20`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 173 LUT-class, 0 DSP-class (budget 240 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
