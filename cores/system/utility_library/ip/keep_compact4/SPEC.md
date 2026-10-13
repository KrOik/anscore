# keep_compact4

Compact bytes of a selected by b[3:0], lowest lane first; result packed bytes, aux=selected byte count.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("keep_compact4", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
