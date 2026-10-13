# stream_sequence32

Check accepted a against expected sequence. Expected starts at b after reset or c[31]; every beat next expected=a+1. result=next expected,aux=prior expected,fault=mismatch.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("stream_sequence32", a, b, c, state)`. Test vectors: 350. No additional RTL dependencies.
