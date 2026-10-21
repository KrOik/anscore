# addr_scramble

Invertible address scrambler: a three-round 16-bit Feistel permutation with key-derived sub-keys, plus unscramble, host compare and round-trip self-check modes, so a scrambled bank, page and row mapping is always exactly reversible

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Address scrambling must be reversible in the same cycle it is applied, and a three-round Feistel network gives that for free: every stage is a 16-bit add, a rotate and XORs, so forward and inverse share one round function and need no lookup table, no divider and no multiplier, which keeps the whole scramble and decode path single-cycle wide at an initiation interval of 1

Independent integer model: `step("addr_scramble", a, b, c, state)` in tools/fam_memsys.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 128 distinct responses, 4 fault rows.
