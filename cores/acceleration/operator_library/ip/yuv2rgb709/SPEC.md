# yuv2rgb709

BT.709 inverse colour matrix, two pixels per beat. Pixel 0 = (Y,Cb,Cr) = (a[7:0], a[15:8], a[23:16]), pixel 1 = (a[31:24], b[7:0], b[15:8]); b[31:16] and all of c are reserved and must read zero, otherwise result=aux=0 and fault=1. The three channel rows are the exact inverse of the studio encoder above, derived from the same chromaticities in Q10: R = (1192*(Y-16) + 1836*(Cr-128))/1024, G = (1192*(Y-16) - 218*(Cb-128) - 546*(Cr-128))/1024, B = (1192*(Y-16) + 2163*(Cb-128))/1024, each rounded once and clamped to 0..255, with the shared 1192*(Y-16) term evaluated once per pixel and the chroma footpoint folded into the constant. result[7:0..23:16]=R0,G0,B0 and result[31:24]=R1; aux[7:0],aux[15:8]=G1,B1 so a full pixel pair leaves in one beat. aux[16]=pixel 0 clamped, aux[17]=pixel 0 rounded up, aux[18]/aux[19] the same for pixel 1, aux[20]/aux[21]=pixel 0/1 is achromatic, aux[22]/aux[23]=pixel 0/1 carries neutral chroma (Cb=Cr=128), aux[24]/aux[25]=pixel 0/1 code was outside the studio windows 16..235 / 16..240 on input. Stateless.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: The display side of a video path converts two pixels per beat from one shared luma term; a scalar core pays six multiply-accumulates, six clamps and the studio-window expansion per pixel pair and cannot overlap them with the fetch of the next pair.

Independent integer model: `step("yuv2rgb709", a, b, c, state)` in tools/fam_video.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 126 distinct responses, 3 fault rows.
