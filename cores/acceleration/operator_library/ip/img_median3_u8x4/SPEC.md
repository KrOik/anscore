# img_median3_u8x4

Per-lane median of three unsigned bytes (rank 1 of 3), four lanes deep. Lane k reads A=a[8k+:8], B=b[8k+:8], C=c[8k+:8] and writes result[8k+:8]=median(A,B,C) as max(min(A,B),min(max(A,B),C)) - three comparators per lane, no adder, no sort. aux[3:0]=lanes where at least two of the three inputs are equal (a tie, so the median is also the min or the max). aux[7:4]=lanes where all three inputs are equal. aux[31:8] is always zero. No fault condition: every input word is a legal triple and a median of bytes can never overflow.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Salt-and-pepper rank filtering costs three compares and two branches per pixel in firmware; four lanes of the min/max network settle in one cycle, so the sensor pipeline moves 4 pixels per enabled beat with the tie flags produced in the same beat.

Independent integer model: `step("img_median3_u8x4", a, b, c, state)` in tools/fam_image.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 111 distinct responses, 0 fault rows.
