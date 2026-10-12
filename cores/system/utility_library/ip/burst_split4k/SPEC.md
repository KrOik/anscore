# burst_split4k

a=address,b=remaining positive bytes,c=positive maximum chunk; result=min(b,c,bytes until4K), aux=b-result. Zero lengths fault.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("burst_split4k", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
