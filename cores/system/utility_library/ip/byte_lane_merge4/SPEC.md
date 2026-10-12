# byte_lane_merge4

Merge a and b under c[3:0] byte write enables (1 selects b). aux=expanded mask.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("byte_lane_merge4", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
