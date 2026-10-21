# round_robin8

a[7:0]=requests,b[7:0]=enable mask,c[31]=restart pointer0. result=onehot grant,aux=grant index or8 if none. Pointer advances only on nonzero grant.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("round_robin8", a, b, c, state)`. Test vectors: 366. No additional RTL dependencies.
