# gw2a_ips_perf_event_ctr

Eight programmable event counters with strobe AND/OR mux, snapshot and overflow capture

- Series: `ips` (ip_series_20k), family `obs`.
- Core RTL: `src/ips_perf_event_ctr.v`; testbench `sim/tb_ips_perf_event_ctr.v`; independent golden model `models/ips_perf_event_ctr.py`.
- Packaged wrapper: `gw2a_ips_perf_event_ctr.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `ED71D39C` == golden model digest `ED71D39C`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 310 LUT-class, 0 DSP-class (budget 320 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
