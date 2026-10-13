# onehot_guard32

a must have exactly one bit set unless c[0] permits zero. result=bit index or32 for zero; aux=population count; fault on violation.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("onehot_guard32", a, b, c, state)`. Test vectors: 374. No additional RTL dependencies.
