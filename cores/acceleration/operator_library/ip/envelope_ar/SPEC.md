# envelope_ar

Attack/release envelope follower for a level meter or a limiter side chain: instant attack, exponential release e = e - (e >> K) with K = c[2:0] + 1 (1..8), optional peak hold when c[3] = 1, and a meter range switch c[5:4] that shifts the reported level by 0/1/2/3 bits (x1, x2, x4, x8). a is the s12 sample, c[31] restarts with an empty envelope, c[30:6] must be zero. The envelope itself is a 20-bit Q8 accumulator so the release keeps sub-LSB resolution. result = (e >> 8) shifted by the range and clamped to 2047, 12-bit unsigned (zero extended, it is a magnitude). aux[0] = restart echo, aux[1] = release step taken, aux[2] = attack taken, aux[3] = output clamped, aux[5:4] = range, aux[8:6] = K-1, aux[9] = hold mode, aux[29:10] = the whole Q8 envelope. fault = output clamped or malformed control.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: An envelope follower in software pays a multiply and a float convert per sample; here the release is one floor shift off a Q8 accumulator and the range switch is a shifter, so a full attack/release/hold meter retires a sample per enabled beat with no DSP slice, and the 20-bit state leaves 236 bits of the kernel word free for whatever the group needs next.

Independent integer model: `step("envelope_ar", a, b, c, state)` in tools/fam_audio.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 109 distinct responses, 78 fault rows.
