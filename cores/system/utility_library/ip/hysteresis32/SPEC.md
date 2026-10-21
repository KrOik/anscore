# hysteresis32

a=unsigned sample,b=low,c[30:0]=high,c[31]=restart to0. State goes1 when a>=high,0 when a<=low; middle holds. b>=high faults and preserves state. result=state,aux=changed.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("hysteresis32", a, b, c, state)`. Test vectors: 351. No additional RTL dependencies.
