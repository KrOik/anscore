# pkt_field_extract_variable

Four fields read at runtime bit offsets from the 64-bit pair {b,a} (bit 0 = a[0]). c[3:0]=base bit offset (0..15), widths w0..w3=c[7:4], c[11:8], c[15:12], c[19:16] (0..8; 0=field absent; 9..15 malformed for a byte extractor), c[23:20]=ignored, c[31:24]=declared window in bits (0 is read as 1). Fields are laid back to back: p0=base, p(k+1)=pk+wk. result[8k+7:8k]=field k right aligned in its byte lane, 0 when the field is absent, malformed or out of window. aux[3:0]=field k crosses the a|b word edge (pk<32<pk+wk), aux[7:4]=field k leaves the declared window or the 64-bit pair, aux[11:8]=field k absent (wk==0), aux[15:12]=field k width malformed, aux[23:16]=bits consumed (base plus the widths of the fields actually extracted), aux[31:24]=bit position of the last field extracted (0 when none). fault=any malformed width (then no field is extracted and aux[23:16]=aux[31:24]=0), or any field whose span leaves the window or the pair, or a field starting at or past the window. Stateless: c[31] carries no meaning.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Variable-offset, variable-width fields that straddle the word edge cost a scalar core a rotate plus a mask per field; this reads all four, including the ones that roll over a|b, in one enabled beat.

Independent integer model: `step("pkt_field_extract_variable", a, b, c, state)` in tools/fam_packet.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 110 distinct responses, 60 fault rows.
