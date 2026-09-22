# dsp_complex_mul_s12

One complex multiply per beat on Q12 components: A=(a[11:0] real, a[23:12] imaginary), B=(b[11:0], b[23:12]); bits 31:24 are don't care. real=A.re*B.re-A.im*B.im and imag=A.re*B.im+A.im*B.re, each rounded half-up, shifted right by c[3:0] (real) and c[7:4] (imag), then cropped to signed 16-bit. result[15:0]=real, result[31:16]=imag. aux[7:0]=c[7:0] echoed, aux[8]=real cropped, aux[9]=imag cropped, aux[31:10]=0. fault=1 on any crop or on nonzero c[31:8] (result=aux=0).

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Four slices retire a full complex multiply in one beat: this is the QAM equaliser and OFDM subcarrier step that needs four multiplies and two reduction branches on a CPU.

Independent integer model: `step("dsp_complex_mul_s12", a, b, c, state)` in tools/fam_dsp.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 112 distinct responses, 9 fault rows.
