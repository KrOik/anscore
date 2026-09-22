# dsp_dot4_s12_pipe

Four-tap fixed-kernel decimator on Q12 signed samples: x0=a[11:0], x1=a[23:12], x2=b[11:0], x3=b[23:12] (bits 31:24 don't care) against the binomial taps 512/1536/1536/512 (Q12, unity gain at shift 12), so sum=x0*512+x1*1536+x2*1536+x3*512. sum is rounded half-up, shifted right by c[3:0] and cropped to signed 16-bit into result[15:0] (result[31:16]=0). aux[26:0]=sum, aux[27]=1 when the crop fired, aux[31:28]=the shift actually applied. fault=1 when the crop fired. Response latency is 4 enabled beats and the pipeline accepts one beat per enabled cycle while the tail is ready.

See [common interface](../../doc/INTERFACE.md). Latency: 4 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Four hard slices plus a registered adder tree retire a 4-tap kernel every enabled beat; a soft processor would need four multiply instructions and three adds in one instruction slot.

Independent integer model: `step("dsp_dot4_s12_pipe", a, b, c, state)` in tools/fam_dsp.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 110 distinct responses, 37 fault rows.
