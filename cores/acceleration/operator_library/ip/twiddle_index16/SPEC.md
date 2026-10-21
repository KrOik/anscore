# twiddle_index16

Twiddle index generator: turns (L, s, j) of an FFT schedule into a first-quadrant (cos,sin) ROM address plus the swap/negate signs that reconstruct W^e in any quadrant, with XOR, shift and add only - no multiplier and no modulo divide. a[3:0]=L (log2 N, 2..12), a[7:4]=s, a[19:8]=j, a[31:20]=0; b[0]=1 requests the conjugate exponent for an inverse transform, b[31:1]=0; c[0]=mode (0=Stockham radix-2 row: e=(j mod 2^(L-s-1))*2^s with s<L and j<N/2; 1=radix-4 in-place DIF pass: e=(j mod 2^(L-2s-2))*2^(2s) with L even, s<L/2 and j<N/4), c[31:1]=0. Anything else, including out-of-range L, s or j, is a malformed beat (result=aux=0, fault=1). result[11:0]=ROM address (e mod 2^(L-2)), result[13:12]=quadrant q, result[14]=swap re/im, result[15]=negate re, result[16]=negate im, result[17]=inverse echo, result[18]=mode echo, result[31:19]=0. aux[11:0]=exponent e, aux[15:12]=s, aux[19:16]=L, aux[23:20]=log2 of the ROM depth (L-2), aux[31:24]=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: One beat turns any stage/row of a 4096-point schedule into a ROM address and three sign bits, so a quarter-turn table of 2^(L-2) entries serves the whole transform instead of a full-period table four times the size. The work is two masks, two shifts and one XOR: no multiply, no divide and no compare loop, which is what lets it sit at II=1 beside the slices.

Independent integer model: `step("twiddle_index16", a, b, c, state)` in tools/fam_fft.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 124 distinct responses, 5 fault rows.
