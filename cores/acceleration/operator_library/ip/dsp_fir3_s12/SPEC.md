# dsp_fir3_s12

Three-tap FIR with runtime coefficients. State layout: [11:0]=w0, [23:12]=w1, [35:24]=w2, [47:36]=h0 (previous input), [59:48]=h1 (the one before). A config beat (c[31]=1) loads w0=a[11:0], w1=a[23:12], w2=b[11:0], keeps the history, and echoes it: result[11:0]=w2, aux[11:0]=w0, aux[23:12]=w1, all other bits zero. A data beat (c[31]=0) takes x=a[11:0] and computes y=round_half_up((x*w0+h0*w1+h1*w2)>>>c[7:4]) cropped to signed 16-bit: result[15:0]=y, result[31:16]=0, aux[11:0]=x, aux[23:12]=h0, aux[24]=cropped, aux[31:25]=0; then h1<=h0 and h0<=x. Any nonzero c[30:8] is a malformed beat (result=aux=0, fault=1, state kept); fault is also set when y is cropped.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Coefficient reload plus a 3-tap kernel in one beat: the fabric holds the history in registers and applies three products in parallel, so retuning a filter is one write instead of a rebuilt inner loop.

Independent integer model: `step("dsp_fir3_s12", a, b, c, state)` in tools/fam_dsp.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 108 distinct responses, 15 fault rows.
