# stream_xor_acc32

Accepted-beat XOR accumulator; aux=previous accumulator; c[31] restarts accumulator=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("stream_xor_acc32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
