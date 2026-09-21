# cic_comp_s12

Two-stage cascaded integrator-comb decimator, one s12 sample per accepted beat. c[2:0] is log2(R) and must be 2 or 3 (R = 4 or 8); c[31] restarts the filter by zeroing both integrators, both comb delays and the phase counter before this beat; c[30:3] must be zero. result = sign-extended s12 clamp of the most recent completed group divided by R^2 using a shift. aux[4:0] = overflow flags for integrator 1, integrator 2, comb 1, comb 2 and the s12 output clamp, aux[5] = a group completed on this beat, aux[8:6] = next phase, aux[28:9] = the new first integrator. fault = any overflow flag or malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A CIC decimator is pure add/difference/filter: this retires one input sample per enabled beat with no multiplier and no ROM, and the R^2 gain compensation is a single variable shift, which a software decimator cannot do per sample at II=1.

Independent integer model: `step("cic_comp_s12", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 127 distinct responses, 23 fault rows.
