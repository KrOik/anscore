# round_shift_even32

Unsigned right shift by b (0..31), ties to even; aux=discarded bits. Invalid shift faults.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("round_shift_even32", a, b, c, state)`. Test vectors: 435. No additional RTL dependencies.
