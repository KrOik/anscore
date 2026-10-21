# simd_u8x4_diff_sat_i8

Four signed 8-bit differences d_k=a_k-b_k clamped to [-128,127]. result[8k+:8]=two's complement of the clamped d_k. aux[3:0]=lanes that clamped, aux[7:4]=lanes where a_k<b_k. fault=any clamp.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Background/motion subtraction on 4 pixels per beat, with the sign and clamp flags produced in the same beat instead of a per-pixel compare loop.

Independent integer model: `step("simd_u8x4_diff_sat_i8", a, b, c, state)` in tools/fam_simd.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 117 distinct responses, 83 fault rows.
