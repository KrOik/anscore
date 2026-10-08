# gw2a_ips_cdc_reset_bridge

POR counter plus 2FF reset release bridge, asserts reset on async glitch and reports sticky glitch count

- Series: `ips` (ip_series_20k), family `cdc`.
- Core RTL: `src/ips_cdc_reset_bridge.v`; testbench `sim/tb_ips_cdc_reset_bridge.v`; independent golden model `models/ips_cdc_reset_bridge.py`.
- Packaged wrapper: `gw2a_ips_cdc_reset_bridge.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `0D1D2716` == golden model digest `0D1D2716`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 25 LUT-class, 0 DSP-class (budget 160 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
