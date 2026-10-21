# gw2a_ips_frame_len_crc

Length-prefixed packet framer/deframer with embedded CRC and malformed-frame rejection counter

- Series: `ips` (ip_series_20k), family `pkt`.
- Core RTL: `src/ips_frame_len_crc.v`; testbench `sim/tb_ips_frame_len_crc.v`; independent golden model `models/ips_frame_len_crc.py`.
- Packaged wrapper: `gw2a_ips_frame_len_crc.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `BA2B43E9` == golden model digest `BA2B43E9`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 143 LUT-class, 0 DSP-class (budget 420 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
