# complex_add_sat

Complex add/sub with sample-width saturation: the sum and the difference of two signed 12-bit complex values, with the second operand arithmetic-shifted (floor, no rounding) by a per-beat amount. a[11:0]=x.re, a[23:12]=x.im, b[11:0]=y.re, b[23:12]=y.im signed 12, a[31:24]=b[31:24]=0; c[3:0]=shift k (0..15), c[31:4]=0. Any nonzero reserved bit is a malformed beat (result=aux=0, fault=1). With y'=y>>>k elementwise, result[11:0]=clamp12(x.re+y'.re), result[23:12]=clamp12(x.im+y'.im), result[24]=re clamped, result[25]=im clamped, result[27:26]=0, result[31:28]=k. aux mirrors the difference x-y' in the same layout (aux[24]/aux[25] clamping flags, aux[31:28]=k). fault=1 on a malformed beat or any clamped lane; a clamped lane never wraps. No multiplier is instantiated: the whole cone is shift, add and compare.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A spectral adder/compressor tree needs both the sum and the difference of the same complex pair every beat: four 12-bit saturating lanes and one programmable shift retire in a single beat at II=1 with no divide, no rounding feedback loop and no per-lane branch, which a scalar core pays four times per sample pair.

Independent integer model: `step("complex_add_sat", a, b, c, state)` in tools/fam_fft.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 127 distinct responses, 19 fault rows.
