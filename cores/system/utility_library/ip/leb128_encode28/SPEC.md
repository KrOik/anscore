# leb128_encode28

Unsigned a<2^28 to minimal LEB128, low output byte first; aux=byte count (1..4). Wider inputs fault.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("leb128_encode28", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
