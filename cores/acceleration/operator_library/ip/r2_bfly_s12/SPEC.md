# r2_bfly_s12

Radix-2 butterfly node: (x+y, (x-y)*W) with W restricted to the four axis values 1,-j,-1,+j scaled by a Q1.10 gain, so two MULT12X12 slices cover the whole twiddled leg at II=1. a[11:0]=x.re, a[23:12]=x.im, b[11:0]=y.re, b[23:12]=y.im (signed 12), a[31:24]=b[31:24]=0. c[11:0]=gain g signed Q1.10 (1024=unity), c[14:12]=axis code t (0=1, 1=-j, 2=-1, 3=+j), c[31:15]=0; any other bit pattern is a malformed beat (result=aux=0, fault=1). result[12:0]=(x+y).re and result[25:13]=(x+y).im signed 13 (the sum of two signed 12-bit values never overflows 13 bits), result[26]=(x-y)*W clipped to the slice width, result[31:29]=t. aux[11:0] and aux[23:12] are the re/im of round_half_up((x-y)*W*g)>>10 clipped to signed 12, aux[24]=re saturated, aux[25]=im saturated, aux[26]=difference clipped, aux[31:27]=0. fault=1 on a malformed beat, a clipped difference or a saturated output lane.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: One butterfly node per beat through two hard slices at II=1: the sum leg and the twiddled difference leg leave together, so a stage of N/2 butterflies is N/2 beats with no per-sample multiply-accumulate loop and no rounding feedback path. The same node in software is two multiplies plus a shift in sequence; here the axis rotation is a wire swap and only the gain costs silicon.

Independent integer model: `step("r2_bfly_s12", a, b, c, state)` in tools/fam_fft.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 111 distinct responses, 8 fault rows.
