# walking_pattern32

a=bit index 0..31, b[0]=0 walking1,1 walking0; result=pattern, aux=next index. Invalid index faults.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("walking_pattern32", a, b, c, state)`. Test vectors: 374. No additional RTL dependencies.
