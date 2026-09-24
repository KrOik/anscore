# simd_u8x4_mad_round

Per-lane gain then offset: value_k=sat_u8((((a_k*b_k)+128)>>8)+c_k) where b_k is a Q8 gain and c_k an unsigned offset. aux[3:0]=lanes clamped at 255. fault=any clamp.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Scale-and-bias on 4 channels per beat for white balance or dither-free gamma: the multiply, rounding shift and bias are one hardwired cone.

Independent integer model: `step("simd_u8x4_mad_round", a, b, c, state)` in tools/fam_simd.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 111 distinct responses, 81 fault rows.
