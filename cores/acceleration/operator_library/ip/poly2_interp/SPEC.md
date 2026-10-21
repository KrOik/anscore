# poly2_interp

Two independent 3-tap quadratic interpolators per accepted beat. Lane 0 reads s8 samples from a[7:0], a[15:8], a[23:16] and uses phase c[1:0]; lane 1 reads b[7:0], b[15:8], b[23:16] and uses phase c[3:2]; the phase selects mu = 0, 1/4, 1/2, 3/4 exact Lagrange weights in Q14. a[31:24] and b[31:24] are ignored and c[31:4] must be zero. result[7:0] and result[15:8] are the s8 clamped lane outputs, aux[1:0] = per-lane clamp flags, aux[15:8] and aux[23:16] = the pre-clamp rounded values. fault = any lane clamped or malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A fractional delay line wants one weighted 3-tap interpolation per output sample per channel: two lanes retire every enabled beat at II=1 with no multiplier and no coefficient load, where software needs a multiply per tap.

Independent integer model: `step("poly2_interp", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 111 distinct responses, 12 fault rows.
