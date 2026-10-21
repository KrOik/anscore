# DVP RX ring repair staging

This directory contains only a proposed patch and directed tests. Original `../dvp_rx/` is read-only and unchanged. This is a repair to an existing IP, not an additional IP.

The original logical N-entry full ring allowed simultaneous read/write at identical RAM address. Physical N+1 storage with unchanged logical capacity N makes read/write addresses distinct. Pointer width becomes clog2(N+1), pointers wrap on N. Existing acceptance and N+1 total capacity including output hold remain intact.

Run `python -B cores/system/common_scaffold/image/dvp_rx_repair/test_ring.py` from repository root. Temporary proposed RTL and executables are created on C: and automatically removed. Five profiles N=2,3,7,1024,4096 pass 20632 total pixels, wrap/range/distance invariants, no simultaneous same-address access, full read+push acceptance, exact capacity, CE-off stall retention and output marker/order checks. Source baseline SHA is checked before and after.

Not yet integrated; full existing DVP suite and synthesis must run after root authorizes integration sequencing. Prior isolated proposal synthesis is documented in `../dvp_tx/rx_ring_proposal.json`: N1024=587 LUT-class/0DSP/6BRAM9, N4096=879/0/14, versus baseline564/0/4 and630/0/12 respectively. Those are earlier synthesis proposal figures, not a new run by this staging task. No board claims.

Integration update: root authorized integration after batch26341 completed. The patch is now applied in ../dvp_rx/ and formal test_ring.py there compiles actual RTL directly. All main/protocol/numeric/ring/synthesis checks passed. Current authoritative source freeze and final_validation are in ../dvp_rx/. Original files are preserved in baseline_before_integration.zip. Earlier staging_evidence.json records the pre-integration temporary-copy experiment and remains historical evidence only.
