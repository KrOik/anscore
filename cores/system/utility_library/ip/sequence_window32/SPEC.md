# sequence_window32

delta=(a-b) modulo 2^32, aux[0]=delta<c and delta<2^31, aux[1]=delta==0. c>=2^31 faults.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("sequence_window32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
