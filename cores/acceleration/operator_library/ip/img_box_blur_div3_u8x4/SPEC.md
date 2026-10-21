# img_box_blur_div3_u8x4

Four independent 3-tap horizontal box averages with exact division by 3. Lane k sums S=a[8k+:8]+b[8k+:8]+c[8k+:8] (0..765), then divides by 3 with the additive-inverse form floor(S/3)=floor(85*S/255), 255=3*85 and 85*S=(S<<6)+(S<<4)+(S<<2)+S: with A=P>>8 and B=P&255, Q=A+(1 when A+B>=255) equals floor(S/3) exactly for S<=765. The residual R=S-2Q-Q is 0, 1 or 2 and result[8k+:8]=Q+(1 when R==2), i.e. round to nearest with the 2/3 case rounding up (a 1/3 tie cannot exist for an odd divisor), which equals (S+1)/3 by floor. aux[3:0]=lanes rounded up (R==2), aux[7:4]=lanes whose sum was an exact multiple of 3 (R==0), aux[31:8] always zero. No fault condition: all three input words are data.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: An integer divide by 3 costs a scalar core a multiply-high plus fix-up or a library call per pixel; here the reciprocal is hardwired and four 3-pixel sums are averaged, rounded and rounding-flagged in one beat.

Independent integer model: `step("img_box_blur_div3_u8x4", a, b, c, state)` in tools/fam_image.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 127 distinct responses, 0 fault rows.
