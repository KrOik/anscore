# token_bucket32

Accepted-beat tokens: refill a, cost b, capacity c[30:0],c[31]=restart. Saturate refill at capacity; grant if cost fits. result=remaining tokens,aux=granted,fault=denied.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("token_bucket32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
