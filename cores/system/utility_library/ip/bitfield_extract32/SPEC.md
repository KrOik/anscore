# bitfield_extract32

Extract c bits at bit offset b, c=0..32; require b+c<=32, b<=31. aux=mask.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("bitfield_extract32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
