# simd_i16x2_sar_rne

Requantise two signed 16-bit lanes of a by arithmetic right shift with round-to-nearest-even. Lane k amount is c[4k+:4]; c[31:8] must be zero. result=rounded lane. aux[7:0]=c[7:0] echoed, aux[9:8]=lanes whose floor quotient was incremented. fault=nonzero c[31:8], with result=aux=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Neural-net requantisation needs ties-to-even at II=1; a scalar core pays a branch or fix-up per value, here both lanes round every enabled beat.

Independent integer model: `step("simd_i16x2_sar_rne", a, b, c, state)` in tools/fam_simd.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 112 distinct responses, 6 fault rows.
