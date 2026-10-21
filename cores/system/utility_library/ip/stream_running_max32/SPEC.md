# stream_running_max32

Unsigned accepted-beat maximum; aux=number of beats modulo2^32; c[31] starts a new run.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("stream_running_max32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
