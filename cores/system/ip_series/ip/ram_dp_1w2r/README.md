# gw2a_ips_ram_dp_1w2r

One-write two-read banked RAM giving three logical ports from two physical dual-ports without collision

- Series: `ips` (ip_series_20k), family `path`.
- Core RTL: `src/ips_ram_dp_1w2r.v`; testbench `sim/tb_ips_ram_dp_1w2r.v`; independent golden model `models/ips_ram_dp_1w2r.py`.
- Packaged wrapper: `gw2a_ips_ram_dp_1w2r.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `347A4563` == golden model digest `347A4563`; 6 literal mutants all detected (4 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 271 LUT-class, 0 DSP-class (budget 300 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
