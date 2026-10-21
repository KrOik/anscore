# tab_ulaw_compress8

G.711 mu-law compressor, 14-bit signed linear input domain, 8-bit code out, one sample per accepted beat. The sample is the signed value in a[13:0] and the stored bias is the canonical 33 (= 0x84 >> 2); segment boundaries come from a generated 8-word image (word s = 2^(s+6)-1, i.e. 63,127,255,511,1023,2047,4095,8191; file line 0 = segment 0) scanned with compares only, so the segment is the first end not exceeded by |x|+33 and the mantissa field is the exact dyadic shift (|x|+33) >> (segment+1): no divide and no multiply. result[7:0] = ((segment<<4)|mantissa) XOR 0xFF for a non-negative sample and XOR 0x7F for a negative one (result[31:8] = 0): 0xFF is positive silence, and because amplitude zero carries no sign, every zero sample encodes as 0xFF while the expander side reads 0x7F as negative silence. aux = (negative<<8) | ((segment<<4)|mantissa), and aux[9] marks a magnitude clamped to 8158, the largest value whose biased sum still fits segment 7. Fault rule: a[31:14] must be the sign extension of a[13]; otherwise result = aux = 0 and fault = 1. b and c are ignored.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: mu-law coding in software is a bias add, a table walk and a magic shift per sample; the fabric retires one sample every enabled beat and exposes the segment, mantissa, sign and clamp as a single aux word for verification.

Independent integer model: `step("tab_ulaw_compress8", a, b, c, state)` in tools/fam_table.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 123 distinct responses, 4 fault rows.
