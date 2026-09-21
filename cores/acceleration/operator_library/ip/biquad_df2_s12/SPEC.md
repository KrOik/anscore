# biquad_df2_s12

Transposed Direct Form II biquad, one s12 sample per accepted beat. a[11:0] is the input; c[1:0] selects P0 lowpass with exact DC gain 2 or P1 DC blocker (values 2 and 3 are malformed); c[31] zeroes both Q14 delay registers before this beat; c[30:2] must be zero. result = sign-extended s12 clamp of round((d0*x + s1)/16384). aux[15:0] and aux[31:16] echo the low 16 bits of the incoming delay registers s1 and s2. fault = output clamp or malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: The two Q14 state registers fold the whole IIR recursion into one beat: the new s1 needs the clamped output of the same beat, which a software loop pays for with a reload; here it is one combinational chain at II=1.

Independent integer model: `step("biquad_df2_s12", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 123 distinct responses, 17 fault rows.
