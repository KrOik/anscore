# usub_borrow32

Unsigned a-b modulo 2^32; aux=(a<b).

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("usub_borrow32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
