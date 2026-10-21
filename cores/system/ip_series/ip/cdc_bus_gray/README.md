# gw2a_ips_cdc_bus_gray

Binary-to-Gray pointer crossing for async FIFO style multi-bit bus coherence

- Series: `ips` (ip_series_20k), family `cdc`.
- Core RTL: `src/ips_cdc_bus_gray.v`; testbench `sim/tb_ips_cdc_bus_gray.v`; independent golden model `models/ips_cdc_bus_gray.py`.
- Packaged wrapper: `gw2a_ips_cdc_bus_gray.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `F7AF1075` == golden model digest `F7AF1075`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 39 LUT-class, 0 DSP-class (budget 180 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
