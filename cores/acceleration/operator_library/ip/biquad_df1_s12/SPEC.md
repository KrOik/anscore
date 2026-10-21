# biquad_df1_s12

Direct Form I biquad over one s12 sample per accepted beat. a[11:0] is the input, c[1:0] selects one of four hardwired Q14 coefficient sets (P0 lowpass, P1 DC blocker, P2 high-gain lowpass (DC gain 4), P3 resonator), c[31] restarts by zeroing the x1/x2/y1/y2 history before this beat, c[30:2] must be zero. result = sign-extended s12 clamp of round(sum(q14 terms)/16384) to [-2048,2047]. aux[11:0]=previous output y1, aux[23:12]=previous input x1, aux[24]=clamped, aux[25]=restart. fault = clamp or malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A four-tap history read, five Q14 coefficient products and a saturating round all retire in one enabled beat at II=1; a DSP does the same with five multiply-accumulates plus a branch for the clamp and no clamped-sample flag.

Independent integer model: `step("biquad_df1_s12", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 125 distinct responses, 14 fault rows.
