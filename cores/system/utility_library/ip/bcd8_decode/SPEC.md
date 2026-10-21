# bcd8_decode

Eight packed decimal digits a to binary; any nibble>9 faults with result=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("bcd8_decode", a, b, c, state)`. Test vectors: 347. No additional RTL dependencies.
