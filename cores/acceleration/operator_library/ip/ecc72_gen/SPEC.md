# ecc72_gen

SECDED(72,64) memory ECC: encode 64 data bits into 8 check bits, verify a received 72-bit word, correct a single-bit error and flag a double-bit error

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: the 8 syndromes are produced by eight parallel AND/reduction-XOR trees over one 64-bit data word, so SECDED encode and decode finish in a single cycle with no multiplier: every fold is carry-free XOR and the only arithmetic is a +1 counter, letting the data word and its check bits be inferred straight into a BRAM ECC row

Independent integer model: `step("ecc72_gen", a, b, c, state)` in tools/fam_memsys.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 128 distinct responses, 22 fault rows.
