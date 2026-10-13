# stuck_fault32

a=observed,b=expected,c=care mask; result=observed0/expected1 bits, aux=observed1/expected0 bits; fault=any mismatch.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("stuck_fault32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
