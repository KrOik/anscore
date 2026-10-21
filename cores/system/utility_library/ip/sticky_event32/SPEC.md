# sticky_event32

Sticky bitmap: result=(previous AND NOT b) OR a; set dominates clear; aux=newly set bits; c[31] restarts previous=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("sticky_event32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
