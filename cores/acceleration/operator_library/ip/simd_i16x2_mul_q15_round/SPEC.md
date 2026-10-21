# simd_i16x2_mul_q15_round

Two Q15 signed 16-bit multiplies. Lane k operands are a[16k+:16] and b[16k+:16]; value=clamp_s16((a_k*b_k + 2^14) >>> 15) using a floor shift. aux[1:0]=lanes clamped. fault=any clamp, which covers (-32768)*(-32768).

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Fixed-point mix/gain stage: two Q15 multiplies with rounding and saturation per beat, no software multiply-high routine.

Independent integer model: `step("simd_i16x2_mul_q15_round", a, b, c, state)` in tools/fam_simd.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 103 distinct responses, 2 fault rows.
