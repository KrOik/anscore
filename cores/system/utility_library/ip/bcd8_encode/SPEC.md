# bcd8_encode

Unsigned binary a<=99999999 to eight packed decimal digits; out-of-range faults.

See [common interface](../../doc/INTERFACE.md). Latency: 2 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("bcd8_encode", a, b, c, state)`. Test vectors: 348. No additional RTL dependencies.
