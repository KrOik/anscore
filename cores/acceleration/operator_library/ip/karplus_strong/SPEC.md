# karplus_strong

Karplus-Strong plucked-string loop, one sample per accepted beat: y(n) = (1 - 2^-E) * (y(n-1) + y(n-M)) / 2 + x(n). a is the s12 excitation sample, c[1:0] selects the loop length M = 4/8/12/16 cells (pitch fs/M at fs = 8000 Hz), c[2] selects the damping exponent E = 4 or 7, c[31] starts a new pluck by clearing the 16-cell line, the pointer and the previous output (that beat rings from silence, its two-tap sum is forced to zero), and c[30:3] must be zero. result is the s12 clamped new cell value, sign extended. aux[3:0] = next pointer, aux[5:4] = M selector, aux[6] = output clamp, aux[7] = restart echo, aux[21:8] = the pre-clamp feedback value. fault = output clamped or malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A plucked-string voice normally wants a delay line in block RAM plus a multiply for the loop gain; here the 16x12 line is a case-mapped register file and the damping is a self-subtracted shifted copy, so a whole tone generator runs at II=1 with no BRAM, no DSP slice and no address multiply, leaving the memory blocks for everything else.

Independent integer model: `step("karplus_strong", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 116 distinct responses, 27 fault rows.
