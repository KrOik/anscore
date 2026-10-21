# tab_gf256_mul

One GF(2^8) product per accepted beat in the AES field (reduction polynomial 0x11B, generator 3), taken from a generated 256-word image (word i = (log[i]<<8) | antilog[i], file line 0 = index 0). Operands are a[7:0] and b[7:0]; bits a[31:8] and b[31:8] are ignored. result[7:0] = antilog of the reduced log sum, result[31:8] = 0. aux = log[a]+log[b] before reduction (0..508), the arithmetic the fabric subtracts 255 from exactly once, since 508 < 2*255. Either operand zero gives result = aux = 0. Declared faultless: the field has no invalid product, so no fault condition exists and the core is used as a pure throughput element.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A software multiply is a two-loop shift-xor walk of about 16 iterations, while this retires a full field product in one enabled beat with two LUT reads and one conditional subtract, and the log sum stays visible on aux.

Independent integer model: `step("tab_gf256_mul", a, b, c, state)` in tools/fam_table.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 112 distinct responses, 0 fault rows.
