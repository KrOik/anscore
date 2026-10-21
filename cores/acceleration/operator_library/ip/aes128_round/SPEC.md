# aes128_round

One AES-128 encryption round on one 32-bit column word. Byte j of a holds the ShiftRows-rotated state byte of row j, so the caller supplies the row-rotated column order. Each byte passes the published SubBytes table ROM (GF(2^8) inverse mod 0x11b then the affine map y ^ rot1(y) ^ rot2(y) ^ rot3(y) ^ rot4(y) ^ 0x63), then MixColumns over 0x11b in its hardware form out_j = xtime(s_j ^ s_j1) ^ s_j1 ^ s_j2 ^ s_j3 with subscripts mod 4, which is the published 2a + 3b + c + d matrix, where xtime is a shift-add step and never a multiply. b is the round-key column word XORed last. c[31]=1 selects the final round (no MixColumns). c[7:0] is the column index and must be 0..3 and c[29:8] must be zero, else f=1 with r=x=0. x[3:0]=1 per byte that entered the ROM as 0x00 (the inverse-of-zero bypass), x[15:8]=echo of c[7:0].

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A full AES round - substitute, mix, key add - closes in one combinational cone per column, so 4 beats retire a whole AES state block at II=1 instead of a per-byte software loop over a table.

Independent integer model: `step("aes128_round", a, b, c, state)` in tools/fam_crypto.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 124 distinct responses, 2 fault rows.
