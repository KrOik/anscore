# gw2a_ips_pdm_decim16

1-bit PDM to 16-bit PCM decimator, three cascaded integrator-comb stages of order 3, OSR 16

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_pdm_decim16.v`; testbench `sim/tb_ips_pdm_decim16.v`; independent golden model `models/ips_pdm_decim16.py`.
- Packaged wrapper: `gw2a_ips_pdm_decim16.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `66743FAA` == golden model digest `66743FAA`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 254 LUT-class, 0 DSP-class (budget 380 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
