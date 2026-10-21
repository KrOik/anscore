# dsp_iir_lpf_s12

One-pole IIR low pass on signed 11-bit samples: x=a[10:0], gain g=b[10:0] as an unsigned Q10 coefficient (unity at 1024, up to 1.999); all other bits of a and b are don't care. state[10:0] holds the previous output y and c[31] seeds it from x instead (filter restart). e=x-y, delta=round_half_up(e*g>>>10), y_new=clamp_s11(y+delta). result[10:0]=y_new, result[31:11]=0. aux[11:0]=e, aux[12]=clamped high, aux[13]=clamped low, aux[26:14]=delta, aux[31:26]=0. fault=1 only when the 11-bit output saturated, which needs a gain above about 1.5.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A recursive filter needs its feedback loop closed inside one enabled beat; the slice does multiply-then-accumulate every cycle, which a soft-processor loop cannot sustain at a fixed control rate.

Independent integer model: `step("dsp_iir_lpf_s12", a, b, c, state)` in tools/fam_dsp.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 119 distinct responses, 11 fault rows.
