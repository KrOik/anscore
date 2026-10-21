# dsm2_mod

Second-order 1-bit sigma-delta modulator in the canonical CIFB topology with all loop coefficients equal to 1/2, so the whole noise-shaping loop is two shift-add integrators plus a sign test and no multiplier. a is the s12 input; c[1:0] picks how many oversampled sub-steps (1..4) the beat retires with that same input, c[31] clears both integrators first, and c[30:2] must be zero. result is the 1-bit DAC level as +/-2046, sign extended. aux[0] = the last sub-step bit, aux[3:1] = how many of this beat's sub-steps went high, aux[4] = an integrator clamped (the loop left the s12 +/-1.0 full-scale stable range), aux[5] = restart echo, aux[19:8] and aux[31:20] = the new x1 and x2 integrator states in s12. fault = any integrator clamped or malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: One beat can retire up to four oversampled modulator steps through an unrolled shift-add loop, so a Class-D output bit stream at 1 MHz costs a quarter of the sample-rate budget in software; the loop needs no multiplier, no ROM and 32 bits of state, which is what makes 50 parallel modulators fit next to the rest of the audio path.

Independent integer model: `step("dsm2_mod", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 125 distinct responses, 12 fault rows.
