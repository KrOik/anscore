# stream_credit32

Credit ledger: add a then spend b; c[31] resets credit=0. On 33-bit add overflow or insufficient credit, fault and preserve old credit. result=credit,aux=spent (0 on fault).

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("stream_credit32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
