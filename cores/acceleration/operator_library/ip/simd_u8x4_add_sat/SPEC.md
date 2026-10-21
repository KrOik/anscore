# simd_u8x4_add_sat

Four independent unsigned 8-bit saturating adders. Lane k reads a[8k+:8] and b[8k+:8]. result[8k+:8]=min(a_k+b_k,255). aux[3:0]=lanes that saturated. fault=any lane saturated. No lane ever wraps.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A scalar core needs one saturating-add instruction per pixel; this retires 4 pixels every enabled cycle at II=1 and the overflow path is not a branch.

Independent integer model: `step("simd_u8x4_add_sat", a, b, c, state)` in tools/fam_simd.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 99 distinct responses, 111 fault rows.
