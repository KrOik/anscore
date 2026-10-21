# pkt_header_validate4

Four packed 16-bit header fields per beat (halfword 0 is the low half): LEN=a[15:0], TYPE=a[31:16], VERW=b[15:0], FLAGS=b[31:16]. Config c[7:0]=runt bound, jumbo limit={c[15:8],8'h00}, c[23:16]=highest legal TYPE, c[31:24]=bit mask of legal versions over nibble 0..7 (8..15 illegal). Checks: LEN<runt=runt, LEN>jumbo=jumbo, LEN[1:0]!=0=truncated; TYPE==0=reserved type, TYPE>c[23:16]=unknown type; VERW[15:4]!=0=upper bits set, version=VERW[3:0]>7=illegal nibble, version bit clear in c[31:24]=disabled; FLAGS[15:6]!=0=reserved bits set, FLAGS[5](MF)&FLAGS[4](DF) both set=conflict. result[3:0]=per-field PASS mask (1=field clean), result[4]=all four clean, result[19:8]=ceil(LEN/32) beats, result[31:20]=0. aux[3:0]=LEN [runt,jumbo,truncated,field-any], aux[7:4]=TYPE [reserved0,unknown,field-any,0], aux[11:8]=VER [upper_bits,illegal_nib,disabled,field-any], aux[15:12]=FLAGS [reserved,df_mf,field-any,global]. fault=aux[15], any check fired. Stateless: c[31] carries no meaning.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 4. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: Four fields are policed against four different rule sets in one beat with no branches; a scalar loop pays a load, a compare and a shift per field and must re-read them to report which checks fired.

Independent integer model: `step("pkt_header_validate4", a, b, c, state)` in tools/fam_packet.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 128 distinct responses, 118 fault rows.
