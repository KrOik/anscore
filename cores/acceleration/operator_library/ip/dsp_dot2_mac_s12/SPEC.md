# dsp_dot2_mac_s12

Two-tap dot product folded into a long accumulator: x0=a[11:0], x1=a[23:12], g0=b[11:0], g1=b[23:12] (all signed Q12). A nonzero a[31:24] or b[31:24] is a malformed beat (result=aux=0, fault=1, state kept). dot=x0*g0+x1*g1 is added to a 48-bit signed accumulator in state[47:0]; c[31] clears the accumulator before this beat. result=the accumulator clamped to signed 32-bit, fault=1 when that clamp bites. aux[15:0]=accumulator[15:0], aux[31:16]=accumulator[47:32].

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Two multipliers and one accumulate inside a single enabled beat: a 2-tap section of a larger filter runs at II=1 with no coefficient fetch.

Independent integer model: `step("dsp_dot2_mac_s12", a, b, c, state)` in tools/fam_dsp.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 101 distinct responses, 4 fault rows.
