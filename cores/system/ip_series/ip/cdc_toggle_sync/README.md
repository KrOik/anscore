# gw2a_ips_cdc_toggle_sync

Two-flop toggle synchroniser with data-stable-before-req rule and transfer/error counters

- Series: `ips` (ip_series_20k), family `cdc`.
- Core RTL: `src/ips_cdc_toggle_sync.v`; testbench `sim/tb_ips_cdc_toggle_sync.v`; independent golden model `models/ips_cdc_toggle_sync.py`.
- Packaged wrapper: `gw2a_ips_cdc_toggle_sync.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `37849058` == golden model digest `37849058`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 23 LUT-class, 0 DSP-class (budget 120 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
