# redundancy_compare32

result=bitwise majority of a,b,c; aux=bits where replicas disagree; fault=any disagreement. Does not assert TMR physical fault tolerance.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("redundancy_compare32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
