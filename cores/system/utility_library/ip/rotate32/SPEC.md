# rotate32

Rotate a by b[4:0]; c[0]=0 left, 1 right.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("rotate32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
