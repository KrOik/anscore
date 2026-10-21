# biquad_cascade_step

Two-section cascade stepped in one accepted beat. a[11:0] is the s12 input; section 1 is a Q14 lowpass with exact DC gain 2, section 2 is the 0.5/0.5 DC blocker and is bypassed when c[0]=1. c[31] zeroes all six 12-bit history fields before this beat; c[30:1] must be zero. result = sign-extended s12 clamp of section 2 (or of section 1 when bypassed). aux[11:0] = section-1 output, aux[12] = section-1 clamped, aux[13] = section-2 clamped, aux[14] = bypass, aux[15] = restart. fault = either section clamped, or malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Two biquad sections in series normally cost two memory round-trips per sample; here section 2 consumes the clamped section-1 result in the same beat at II=1, and each section reports its own clamp bit.

Independent integer model: `step("biquad_cascade_step", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 127 distinct responses, 10 fault rows.
