# event_counter32

Add popcount(a AND b) into saturating event counter; aux=this beat count; fault=saturation. c[31] restarts counter=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("event_counter32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
