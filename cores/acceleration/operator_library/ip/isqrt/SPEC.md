# isqrt

Restoring integer square root of the 32-bit unsigned operand a, one bit pair per accepted beat. Seed beat (c[31]=1) loads rem=a (33 bits), root=0, bit index 15 and reports that seed; later beats test bits 14..0. A test forms add=(root<<(i+1))|(1<<(2i)) - the exact increase of root^2 when bit i is set - and keeps the bit only when rem>=add, so the state invariant rem = a-root^2 holds every beat and the running root is floor(sqrt of the high bits seen so far). After bit 0 the done flag is set and a beat with c[31]=0 repeats the converged answer. result=root=floor(sqrt(a)) (16 bits, result[31:16]=0), aux[4:0]=next bit index tested, aux[5]=converged, aux[6]=idle repeat, aux[31:7]=low 25 bits of the remainder a-root^2. No input is invalid, so this core is declared faultless.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: The 33-bit addend (root<<(i+1))|(1<<(2i)) is a wired shift, not a multiplier, so a 32-bit root costs 17 enabled beats and zero slices while the remainder invariant stays visible on aux every beat. A CPU has no integer-square-root instruction at this width and pays a compare, a subtract and a shift per bit pair in software.

Independent integer model: `step("isqrt", a, b, c, state)` in tools/fam_arith.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 128 distinct responses, 0 fault rows.
