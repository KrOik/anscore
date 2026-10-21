# range_guard32

Unsigned a in inclusive [b,c]; result=a if valid else0; aux[0]=below,aux[1]=above,aux[2]=invalid bounds; faults on any violation.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("range_guard32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
