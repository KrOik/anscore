# thermometer_decode32

Decode low contiguous ones; result=ones count. Holes fault, with result=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("thermometer_decode32", a, b, c, state)`. Test vectors: 375. No additional RTL dependencies.
