# gw2a_ips_kbd_matrix_scan

8x8 keyboard matrix scanner with key-roll-over capture and ghost detection

- Series: `ips` (ip_series_20k), family `ctrl`.
- Core RTL: `src/ips_kbd_matrix_scan.v`; testbench `sim/tb_ips_kbd_matrix_scan.v`; independent golden model `models/ips_kbd_matrix_scan.py`.
- Packaged wrapper: `gw2a_ips_kbd_matrix_scan.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `44ED6307` == golden model digest `44ED6307`; 6 literal mutants all detected (2 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 283 LUT-class, 0 DSP-class (budget 320 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
