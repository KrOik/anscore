# parity_lane32

result[3:0]=even parity of each byte in a; compare to b[3:0] when c[0]=1, aux=mismatching lanes, fault=any mismatch.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("parity_lane32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
