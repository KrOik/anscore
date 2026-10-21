# gw2a_ips_rle_codec

Run-length encode and decode over a byte stream with literal/run token packing

- Series: `ips` (ip_series_20k), family `pkt`.
- Core RTL: `src/ips_rle_codec.v`; testbench `sim/tb_ips_rle_codec.v`; independent golden model `models/ips_rle_codec.py`.
- Packaged wrapper: `gw2a_ips_rle_codec.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `4463BB78` == golden model digest `4463BB78`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 213 LUT-class, 0 DSP-class (budget 320 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
