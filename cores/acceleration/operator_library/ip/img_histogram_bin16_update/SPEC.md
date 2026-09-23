# img_histogram_bin16_update

16-bin histogram accumulated in state: state[(k*16)+:16] is bin k, so the array occupies exactly 16*16=256 bits. Each beat folds 8 pixels, one 32-bit word per half plane, with bin index = pixel>>4 for a[7:0], a[15:8], a[23:16], a[31:24], b[7:0], b[15:8], b[23:16], b[31:24]. Control c: c[31]=restart (every bin cleared before the increments), c[30]=preload (every bin set to the byte broadcast {pv,pv} with pv=c[23:16], so pv=0xff arms the 65535 ceiling), c[7:4]=bin to read out, and c[3:0], c[15:8] and c[29:24] must be zero; restart beats preload. result[15:0]=bin c[7:4] as of the start of this beat, result[31:16]=that bin after this beat, so one beat reads a bin out and re-arms it. aux[15:0]=bins that hit the 16-bit ceiling and were held at 65535, aux[31:16]=bins that went from empty to non-empty this beat. fault=any bin overflow, or malformed control (then result=aux=0 and state is left exactly as it was). All 16 bins are compared against all 8 pixel nibbles and incremented in the same beat.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 8. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A histogram step is a read-modify-write plus a store-forward stall per pixel in firmware; here 16 bins are matched against 8 pixel nibbles and incremented, saturated and flagged in a single enabled beat, with a zero-latency read-out port on any one bin.

Independent integer model: `step("img_histogram_bin16_update", a, b, c, state)` in tools/fam_image.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 119 distinct responses, 15 fault rows.
