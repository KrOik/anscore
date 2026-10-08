# gw2a_ips_cdc_handshake_2ff

4-phase req/ack handshake crossing for a multi-bit word, data launched one source cycle before req

- Series: `ips` (ip_series_20k), family `cdc`.
- Core RTL: `src/ips_cdc_handshake_2ff.v`; testbench `sim/tb_ips_cdc_handshake_2ff.v`; independent golden model `models/ips_cdc_handshake_2ff.py`.
- Packaged wrapper: `gw2a_ips_cdc_handshake_2ff.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `BE79F36E` == golden model digest `BE79F36E`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 33 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
