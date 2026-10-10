# gw2a_ips_sync_marker_stuffer

Inserts and removes a byte-oriented sync marker with escape/unescape transparency

- Series: `ips` (ip_series_20k), family `pkt`.
- Core RTL: `src/ips_sync_marker_stuffer.v`; testbench `sim/tb_ips_sync_marker_stuffer.v`; independent golden model `models/ips_sync_marker_stuffer.py`.
- Packaged wrapper: `gw2a_ips_sync_marker_stuffer.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `1496FF8A` == golden model digest `1496FF8A`; 6 literal mutants all detected (4 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 192 LUT-class, 0 DSP-class (budget 280 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
