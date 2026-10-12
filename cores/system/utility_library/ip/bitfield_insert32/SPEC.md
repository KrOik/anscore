# bitfield_insert32

Insert low c[13:8] bits of b into a at c[5:0]; require offset<32,width<=32,offset+width<=32. aux=destination mask.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("bitfield_insert32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
