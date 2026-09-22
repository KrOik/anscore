# goertzel_dtmf

Goertzel tone recursion s(n) = x(n) + c1*s(n-1) - s(n-2) with c1 = 2*cos(2*pi*f/fs) for the eight ITU-T Q.23 DTMF tones (697/770/852/941/1209/1336/1477/1633 Hz at fs = 8000), selected by c[2:0]. Each c1 is a Q14 constant expanded into signed power-of-two shifts, so the core has no multiplier. The accumulator is Q12 in a 26-bit clamping field (+/-8191.99 signal units). a is one s12 sample per accepted beat; c[31] zeroes both accumulators before the beat and must accompany any bin change, which is otherwise flagged malformed together with the reserved bits c[30:3]. result = (|s(n)|+|s(n-1)|) rounded, in units of two signal magnitudes, as the energy proxy for the decision stage; 12-bit unsigned clamped at 2047 (zero-extended, not sign-extended: it is a magnitude). aux[30:28] = bin, aux[27:16] = |s(n)|>>14, aux[15:4] = |s(n-1)|>>14 (quarter signal units), aux[3] = energy clamp, aux[2] = accumulator clamp, aux[0] = the restart bit. fault = accumulator clamp | energy clamp | malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A dual-tone detector usually costs two multipliers per bin and a window RAM; here every c1 is a shift-add list and the whole state is 56 flip flops, so eight tone bins fit in the LUTs next to the sample path and flag themselves the moment their accumulator rails, with no DSP slice and no block RAM occupied.

Independent integer model: `step("goertzel_dtmf", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 119 distinct responses, 25 fault rows.
