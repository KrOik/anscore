# img_sobel_mag_u8

Sobel 3x3 gradient magnitude of one packed window. Tap packing: row0 = p00=a[7:0], p01=a[15:8], p02=a[23:16]; row1 = p10,p11,p12 from b; row2 = p20,p21,p22 from c. a[31:24], b[31:24], c[31:24] are padding and must be zero. Exact integer (1,2,1) weights as shifts and adds only: Gx=(p02+2*p12+p22)-(p00+2*p10+p20) and Gy=(p20+2*p21+p22)-(p00+2*p01+p02), both magnitudes formed by compare-then-subtract so no signed datapath is needed. result[7:0]=min(|Gx|+|Gy|,255). aux[0]=Gx<0, aux[1]=Gy<0, aux[2]=the magnitude was clipped to 255; aux[31:3] are always zero. fault=any nonzero padding byte in a, b or c, with result=aux=0. No state.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A scalar core pays a load, two shifted adds, a subtract, an absolute value and a clip per pixel; this cone retires a whole 3x3 Sobel window every enabled beat at II=1 and hands the gradient signs out beside the magnitude, so edge direction costs nothing.

Independent integer model: `step("img_sobel_mag_u8", a, b, c, state)` in tools/fam_image.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 116 distinct responses, 6 fault rows.
