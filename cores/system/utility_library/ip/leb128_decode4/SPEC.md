# leb128_decode4

Decode b=1..4 low bytes of a, require canonical minimal unsigned LEB128 with terminal continuation=0; unused bytes ignored. aux=length. Malformed input faults with result=aux=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("leb128_decode4", a, b, c, state)`. Test vectors: 353. No additional RTL dependencies.
