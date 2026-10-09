# gw2a_ips_fifo_sync_fwft

Synchronous FIFO, first-word-fall-through output, concurrent read/write, level and programmatic flag watermarks

- Series: `ips` (ip_series_20k), family `path`.
- Core RTL: `src/ips_fifo_sync_fwft.v`; testbench `sim/tb_ips_fifo_sync_fwft.v`; independent golden model `models/ips_fifo_sync_fwft.py`.
- Packaged wrapper: `gw2a_ips_fifo_sync_fwft.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `8EA4D0AB` == golden model digest `8EA4D0AB`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 178 LUT-class, 0 DSP-class (budget 340 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
