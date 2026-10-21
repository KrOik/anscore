# tdm8_demux

Eight-slot TDM receiver: every accepted beat carries one 16-bit slot word in a[15:0] with its claimed slot index in c[2:0], c[31] re-synchronises the receiver onto that slot instead of the expected one, and c[30:3] must be zero. The word is routed into that channel of eight 16-bit channel registers, and three integrity checks are made of bit tests and compares only: over-range (a valid audio slot is s12 inside s16, so a[15:12] must equal the sign bit replicated four times), sequence (the slot index has to match the running expected-slot counter) and lock (an eight-bit seen bitmap, full at 0xFF). result = the routed slot word, sign extended from s16. aux[15:0] = the fold-down sum of all eight channel registers, aux[23:16] = the seen bitmap, aux[26:24] = this slot index, aux[27] = over-range, aux[28] = sequence error, aux[29] = frame lock, aux[30] = restart echo. fault = over-range or sequence error, or malformed control (which also drops lock).

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A TDM demultiplexer in software is a switch and a sign test per sample; here eight registered channels, the seen-bitmap lock tracker and the fold-down monitor all update in one enabled beat with no multiplier, no block RAM and 139 bits of state, so the receiver can watch every slot of the bus while the audio path keeps its DSP slices.

Independent integer model: `step("tdm8_demux", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 128 distinct responses, 8 fault rows.
