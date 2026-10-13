# minmax_signed32

Signed minimum of a,b in result; maximum in aux.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("minmax_signed32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
