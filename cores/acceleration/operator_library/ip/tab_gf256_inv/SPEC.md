# tab_gf256_inv

Four independent GF(2^8) multiplicative inverses per accepted beat, packed lane 0 = a[7:0] ... lane 3 = a[31:24], using the same generated 256-word log/antilog image as tab_gf256_mul (word i = (log[i]<<8) | antilog[i], file line 0 = index 0). For a non-zero byte the inverse is antilog[255-log[byte]]. Lane k of result[8k+:8] is that inverse and lane k of aux[8k+:8] is the antilog index 255-log, which is 1..255 (byte 1 maps to index 255). b and c are ignored. Fault rule: the inverse of zero is undefined, so any zero byte sets fault and that lane keeps result = aux = 0 while the other lanes still return their own inverse.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: AES/Rijndael SubBytes and the inverse step of elliptic-curve software pay a table indirection per byte; here four inverses plus their exponents come back from one fabric-LUT read set every enabled beat at II=1.

Independent integer model: `step("tab_gf256_inv", a, b, c, state)` in tools/fam_table.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 127 distinct responses, 12 fault rows.
