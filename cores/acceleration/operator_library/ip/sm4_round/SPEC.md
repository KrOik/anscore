# sm4_round

SM4 encryption round (GB/T 32907-2016 section 5.2) over the rolling four words in state, slot j = X i+j at bits 32j..32j+31. A round beat requires c[30:0] = 0 and takes the round key rk in b: A = X1 ^ X2 ^ X3 ^ rk, B = SubWords(A) through the published 256-byte SM4 S-box as a table ROM, T = L(B) = B ^ rotl(B,2) ^ rotl(B,10) ^ rotl(B,18) ^ rotl(B,24) (the standard L, four rotates and five terms), then X4 = X0 ^ T and the window shifts to (X1,X2,X3,X4): r = X4, x = T. c[31]=1 with c[2]=0 is a load beat writing a into slot c[1:0] and answering r=a, x=80000000|slot, so the 128-bit block is installed in four beats and the ciphertext is the final window read in reverse word order (X35..X32), which is what the standard outputs. f=1 with r=x=0 and the window untouched when c[30:2] is nonzero or when a round beat has c[1:0] nonzero. tau is a case-statement ROM and L is rotate-XOR, so no multiply appears.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: One SM4 round per beat keeps the whole 128-bit block in registers and takes the round key as a descriptor word, so 32 beats finish a block with no key-schedule RAM and no multiplier.

Independent integer model: `step("sm4_round", a, b, c, state)` in tools/fam_crypto.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 123 distinct responses, 6 fault rows.
