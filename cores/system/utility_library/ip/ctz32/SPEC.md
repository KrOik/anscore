# ctz32

Trailing zero count in a, including ctz(0)=32.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("ctz32", a, b, c, state)`. Test vectors: 374. No additional RTL dependencies.
