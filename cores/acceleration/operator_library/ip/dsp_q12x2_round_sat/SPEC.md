# dsp_q12x2_round_sat

Two independent Q12 signed multiplies per beat: lane k multiplies a[12k+:12] by b[12k+:12] (k=0,1; bits 31:24 are don't care), rounds the Q24 product half-up and shifts it right by c[4k+:4], then crops to signed 16-bit. result=the two 16-bit lanes, lane 0 low. aux[7:0]=c[7:0] echoed, aux[8+k]=lane k was cropped, aux[31:9]=0. fault=1 on a cropped lane or on nonzero c[31:8] (malformed control, result=aux=0).

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A stereo gain stage with per-channel requantisation and saturation reporting: two slices do in one beat what costs a CPU two multiply-high sequences plus two fix-up branches.

Independent integer model: `step("dsp_q12x2_round_sat", a, b, c, state)` in tools/fam_dsp.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 98 distinct responses, 9 fault rows.
