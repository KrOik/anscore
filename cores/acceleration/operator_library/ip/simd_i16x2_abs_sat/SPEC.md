# simd_i16x2_abs_sat

Lane-wise magnitude of the two signed 16-bit values in a. -32768 saturates to 32767. result=|a_k| per lane. aux[1:0]=lanes that saturated. fault=any saturation.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Rectifier for envelope/level metering: the most-negative input is the two's-complement trap, and here it is flagged in the same beat.

Independent integer model: `step("simd_i16x2_abs_sat", a, b, c, state)` in tools/fam_simd.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 100 distinct responses, 15 fault rows.
