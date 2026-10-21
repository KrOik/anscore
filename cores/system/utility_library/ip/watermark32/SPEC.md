# watermark32

Accepted-word unsigned high watermark; aux=current a; c[31] restarts high=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("watermark32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
