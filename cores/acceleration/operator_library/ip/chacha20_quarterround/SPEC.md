# chacha20_quarterround

ChaCha20 quarter round (RFC 8439 section 2.3) as two beats over four words in state, slot j = A,B,C,D at bits 32j..32j+31. c[31]=1 with c[2]=0 is a load beat writing a into slot c[1:0] and answering r=a, x=80000000|slot: that is how the sigma words 61707865 3320646e 79622d32 6b206574 (the little-endian words of "expand 32-byte k"), the eight key words, the counter and the three nonce words are installed. c[31]=0 runs one half of the quarter round, picked by c[0]: 0 gives A+=B; D^=A; rotl(D,16); C+=D; B^=C; rotl(B,12) and 1 gives the same three steps with rotl(D,8) and rotl(B,7), so two beats in that order are exactly the published quarter round. Adds are modulo 2^32 and rotates are shift-or, never a multiply. r = updated A, x = updated D, while B and C stay in the window for the caller to read out of the state. f=1 with r=x=0 and the window untouched when c[29:2] is nonzero, when c[2] is set on a load beat, or when c[1] is set on a compute beat.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 2. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: The stream cipher core retires two of the six ARX steps every beat with all four words live in registers, so a 64-byte ChaCha20 block costs 160 compute beats plus the shuttling loads and no key-schedule memory.

Independent integer model: `step("chacha20_quarterround", a, b, c, state)` in tools/fam_crypto.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 127 distinct responses, 2 fault rows.
