# dsp_mac_s12

Signed 12x12 multiply-accumulate. Only a[11:0] and b[11:0] are read, both two's complement; a nonzero a[31:12] or b[31:12] is a malformed beat (result=aux=0, fault=1, state kept). The product is added to a 48-bit signed accumulator in state[47:0]; c[31] clears that accumulator before this beat. result=the accumulator clamped to signed 32-bit, and fault=1 whenever that clamp bites. aux[15:0]=accumulator[15:0] and aux[31:16]=accumulator[47:32] keep the untruncated magnitude visible.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: One multiply and one accumulate retire per enabled beat with no load/store round trip, which is exactly the filter inner loop a CPU must re-fetch every tap.

Independent integer model: `step("dsp_mac_s12", a, b, c, state)` in tools/fam_dsp.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 102 distinct responses, 4 fault rows.
