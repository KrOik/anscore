# address_boundary4k

a=address,b=positive byte length. result=bytes until 4K boundary; aux[0]=crosses boundary, aux[1]=32-bit address wrap. b=0 faults.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("address_boundary4k", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
