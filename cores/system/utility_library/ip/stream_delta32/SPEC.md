# stream_delta32

Accepted-word delta a-previous modulo2^32; aux=previous; c[31] restarts previous=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("stream_delta32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
