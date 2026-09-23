# lfsr_galois_keystream

Galois (right-shifting) LFSR keystream stage, tap constant 80200003. state[31:0] = register, state[63:32] = running XOR of the keystream bytes, state[95:64] = beats since restart. c[31]=1 restarts with the seed from a (zero seed is a lockup and sets f=1). c[30]=0 runs eight tap-XOR steps per beat and c[30]=1 runs a single step so each tap decision is observable. r = new register, x[7:0] = keystream byte shifted out (LSB first), x[31:8] = beats counter, x[31]=1 on a restart beat. c[29:0] must be zero on a run beat else f=1 with r=x=0, and f=1 if a run beat leaves the register at zero. No multiply: the step is a shift plus a conditional tap XOR.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Eight independent tap-XOR stages fold one keystream byte per beat with the lockup state detected in the same beat, so a seed that cannot generate is flagged instead of silently emitting zeros.

Independent integer model: `step("lfsr_galois_keystream", a, b, c, state)` in tools/fam_crypto.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 115 distinct responses, 16 fault rows.
