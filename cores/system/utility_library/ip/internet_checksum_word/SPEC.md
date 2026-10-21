# internet_checksum_word

Ones-complement sum of a[15:0], b[15:0]; result=folded sum, aux=complement. Words supplied in host numeric order.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("internet_checksum_word", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
