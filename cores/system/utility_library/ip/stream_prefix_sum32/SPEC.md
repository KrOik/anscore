# stream_prefix_sum32

Accepted-beat prefix sum of a modulo2^32; aux=carry on this addition; c[31] restarts sum=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("stream_prefix_sum32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
