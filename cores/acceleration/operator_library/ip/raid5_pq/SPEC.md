# raid5_pq

RAID-5/6 stripe syndrome engine: accumulates the P XOR column and the GF(256) weighted Q column four bytes at a time, verifies host-supplied syndromes, emits both parity columns and refuses an over-full stripe

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Both RAID syndromes are carry-free: P is four byte-lane XOR trees and Q is four GF(256) multiply-accumulates built from xtime shift-xor stages, so a stripe of data columns folds into both parities at one column word per cycle without touching the $mul primitive, which the unsigned GW5A fabric cannot provide for a 256-bit field anyway

Independent integer model: `step("raid5_pq", a, b, c, state)` in tools/fam_memsys.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 100 distinct responses, 16 fault rows.
