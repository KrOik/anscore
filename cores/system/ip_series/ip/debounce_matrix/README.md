# gw2a_ips_debounce_matrix

N-input per-key debounce with stable-count and change-event ledger word

- Series: `ips` (ip_series_20k), family `ctrl`.
- Core RTL: `src/ips_debounce_matrix.v`; testbench `sim/tb_ips_debounce_matrix.v`; independent golden model `models/ips_debounce_matrix.py`.
- Packaged wrapper: `gw2a_ips_debounce_matrix.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `ED06B08D` == golden model digest `ED06B08D`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 258 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
