"""Authored RTL kernels. Reference algorithms live separately in golden.py.

One catalog entry is one independently useful function, never a renamed
parameter configuration. All arithmetic widths and command meanings are in
the generated SPEC.md and per-core manifests.
"""
CORES = []


def core(name, family, spec, body, stateful=False):
    CORES.append(dict(name=name, family=family, spec=spec, body=body,
                      stateful=stateful))


core('uadd_carry32', 'arithmetic', 'Unsigned a+b; result=low32, aux=carry.',
     "ext={1'b0,a}+{1'b0,b}; r=ext[31:0]; x={31'd0,ext[32]};")
core('usub_borrow32', 'arithmetic', 'Unsigned a-b modulo 2^32; aux=(a<b).',
     "r=a-b; x={31'd0,(a<b)};")
core('sadd_overflow32', 'arithmetic', 'Signed a+b modulo 2^32; aux=signed overflow.',
     "r=a+b; x={31'd0,((a[31]==b[31]) && (r[31]!=a[31]))};")
core('ssub_overflow32', 'arithmetic', 'Signed a-b modulo 2^32; aux=signed overflow.',
     "r=a-b; x={31'd0,((a[31]!=b[31]) && (r[31]!=a[31]))};")
core('absdiff32', 'arithmetic', 'Unsigned absolute difference; aux=(a<b).',
     "r=(a<b)?b-a:a-b; x={31'd0,(a<b)};")
core('minmax_signed32', 'arithmetic', 'Signed minimum of a,b in result; maximum in aux.',
     "r=($signed(a)<$signed(b))?a:b; x=($signed(a)<$signed(b))?b:a;")
core('clamp_signed32', 'arithmetic', 'Clamp signed a into signed [b,c]; aux=clipped. b>c faults with result=0.',
     "if($signed(b)>$signed(c)) f=1; else if($signed(a)<$signed(b)) begin r=b; x=1; end else if($signed(a)>$signed(c)) begin r=c; x=1; end else r=a;")
core('round_shift_even32', 'arithmetic', 'Unsigned right shift by b (0..31), ties to even; aux=discarded bits. Invalid shift faults.',
     "if(b>31) f=1; else if(b==0) r=a; else begin mask=32'hffffffff>>(32-b); temp=a>>b; x=a&mask; r=temp+((x>(32'd1<<(b-1))) || ((x==(32'd1<<(b-1))) && temp[0])); end")

core('popcount32', 'bitops', 'Number of set bits in a (0..32).',
     "for(i=0;i<32;i=i+1) r=r+{31'd0,a[i]};")
core('clz32', 'bitops', 'Leading zero count in a, including clz(0)=32.',
     "r=32; for(i=0;i<32;i=i+1) if(a[i]) r=31-i;")
core('ctz32', 'bitops', 'Trailing zero count in a, including ctz(0)=32.',
     "r=32; for(i=31;i>=0;i=i-1) if(a[i]) r=i;")
core('bitreverse32', 'bitops', 'Reverse all 32 bits of a.',
     "for(i=0;i<32;i=i+1) r[i]=a[31-i];")
core('byte_reverse32', 'bitops', 'Reverse the order of the four bytes in a.',
     "r={a[7:0],a[15:8],a[23:16],a[31:24]};")
core('rotate32', 'bitops', 'Rotate a by b[4:0]; c[0]=0 left, 1 right.',
     "if(b[4:0]==0) r=a; else if(c[0]) r=(a>>b[4:0])|(a<<(32-b[4:0])); else r=(a<<b[4:0])|(a>>(32-b[4:0]));")
core('bitfield_extract32', 'bitops', 'Extract c bits at bit offset b, c=0..32; require b+c<=32, b<=31. aux=mask.',
     "if(b>31 || c>32 || ({1'b0,b}+{1'b0,c})>32) f=1; else begin mask=(c==32)?32'hffffffff:((32'd1<<c)-1); r=(a>>b)&mask; x=mask; end")
core('bitfield_insert32', 'bitops', 'Insert low c[13:8] bits of b into a at c[5:0]; require offset<32,width<=32,offset+width<=32. aux=destination mask.',
     "idx=c[5:0]; j=c[13:8]; if(idx>31 || j>32 || idx+j>32) f=1; else begin mask=(j==32)?32'hffffffff:((32'd1<<j)-1); x=mask<<idx; r=(a&~x)|((b&mask)<<idx); end")

core('gray_decode32', 'coding', 'Decode the 32-bit reflected Gray code a to binary.',
     "r[31]=a[31]; for(i=30;i>=0;i=i-1) r[i]=r[i+1]^a[i];")
core('thermometer_decode32', 'coding', 'Decode low contiguous ones; result=ones count. Holes fault, with result=0.',
     "if((a&(a+32'd1))!=0) f=1; else for(i=0;i<32;i=i+1) r=r+{31'd0,a[i]};")
core('bcd8_encode', 'coding', 'Unsigned binary a<=99999999 to eight packed decimal digits; out-of-range faults.',
     "// Dedicated two-stage elastic implementation in generate.py:BCD_PIPELINED.")
CORES[-1]['latency'] = 2
core('bcd8_decode', 'coding', 'Eight packed decimal digits a to binary; any nibble>9 faults with result=0.',
     "for(i=7;i>=0;i=i-1) begin if(a[i*4+:4]>9) f=1; r=(r<<3)+(r<<1)+{28'd0,a[i*4+:4]}; end if(f) r=0;")
core('hamming13_encode8', 'coding', 'SECDED code: 8 data bits a[7:0] in positions 3,5,6,7,9,10,11,12; even parity at 1,2,4,8; overall parity at 13. Position 1 is result bit0.',
     "r[2]=a[0]; r[4]=a[1]; r[5]=a[2]; r[6]=a[3]; r[8]=a[4]; r[9]=a[5]; r[10]=a[6]; r[11]=a[7]; for(j=0;j<4;j=j+1) begin temp=0; for(i=1;i<=12;i=i+1) if((i&(1<<j))!=0) temp[0]=temp[0]^r[i-1]; r[(1<<j)-1]=temp[0]; end r[12]=^r[11:0];")
core('hamming13_decode8', 'coding', 'Decode low13 a. aux[0]=corrected, aux[1]=uncorrectable, aux[7:4]=syndrome. Double errors, impossible syndrome, or high input bits fault; result=0 on fault. No claim for >=3 flips.',
     "temp=a; idx=0; for(j=0;j<4;j=j+1) begin mask=0; for(i=1;i<=12;i=i+1) if((i&(1<<j))!=0) mask[0]=mask[0]^a[i-1]; if(mask[0]) idx=idx|(1<<j); end x=idx<<4; if(a[31:13]!=0) begin f=1; x=x|2; end else if((^a[12:0])==1'b1) begin if(idx>12) begin f=1; x=x|2; end else begin x=x|1; if(idx!=0) temp[idx-1]=~temp[idx-1]; end end else if(idx!=0) begin f=1; x=x|2; end if(!f) r={24'd0,temp[11],temp[10],temp[9],temp[8],temp[6],temp[5],temp[4],temp[2]};")
core('crc16_poly1021_byte', 'coding', 'CRC update: state a[15:0], byte b[7:0], MSB-first, polynomial 0x1021; no initial/final xor.',
     "temp={16'd0,a[15:0]}^{16'd0,b[7:0],8'd0}; for(i=0;i<8;i=i+1) if(temp[15]) temp=((temp<<1)^32'h1021)&32'hffff; else temp=(temp<<1)&32'hffff; r=temp;")
core('crc8_poly07_byte', 'coding', 'CRC update: state a[7:0], byte b[7:0], MSB-first, polynomial 0x07; no initial/final xor.',
     "temp={24'd0,(a[7:0]^b[7:0])}; for(i=0;i<8;i=i+1) if(temp[7]) temp=((temp<<1)^32'h07)&32'hff; else temp=(temp<<1)&32'hff; r=temp;")

core('internet_checksum_word', 'packet', 'Ones-complement sum of a[15:0], b[15:0]; result=folded sum, aux=complement. Words supplied in host numeric order.',
     "ext={17'd0,a[15:0]}+{17'd0,b[15:0]}; temp={16'd0,ext[15:0]}+{31'd0,ext[16]}; r=temp&32'hffff; x={16'd0,~temp[15:0]};")
core('sequence_window32', 'packet', 'delta=(a-b) modulo 2^32, aux[0]=delta<c and delta<2^31, aux[1]=delta==0. c>=2^31 faults.',
     "if(c[31]) f=1; else begin r=a-b; x={30'd0,(r==0),((r<c)&&!r[31])}; end")
core('address_boundary4k', 'packet', 'a=address,b=positive byte length. result=bytes until 4K boundary; aux[0]=crosses boundary, aux[1]=32-bit address wrap. b=0 faults.',
     "if(b==0) f=1; else begin r=4096-{20'd0,a[11:0]}; ext={1'b0,a}+{1'b0,b}-1; x={30'd0,ext[32],(b>r)}; end")
core('burst_split4k', 'packet', 'a=address,b=remaining positive bytes,c=positive maximum chunk; result=min(b,c,bytes until4K), aux=b-result. Zero lengths fault.',
     "if(b==0 || c==0) f=1; else begin temp=4096-{20'd0,a[11:0]}; r=(b<c)?b:c; if(r>temp) r=temp; x=b-r; end")
core('keep_compact4', 'packet', 'Compact bytes of a selected by b[3:0], lowest lane first; result packed bytes, aux=selected byte count.',
     "idx=0; for(i=0;i<4;i=i+1) if(b[i]) begin r[idx*8+:8]=a[i*8+:8]; idx=idx+1; end x=idx;")
core('byte_lane_merge4', 'packet', 'Merge a and b under c[3:0] byte write enables (1 selects b). aux=expanded mask.',
     "for(i=0;i<4;i=i+1) begin r[i*8+:8]=c[i]?b[i*8+:8]:a[i*8+:8]; x[i*8+:8]={8{c[i]}}; end")
core('leb128_encode28', 'packet', 'Unsigned a<2^28 to minimal LEB128, low output byte first; aux=byte count (1..4). Wider inputs fault.',
     "if(a[31:28]!=0) f=1; else begin x=(a<128)?1:(a<16384)?2:(a<2097152)?3:4; for(i=0;i<4;i=i+1) if(i<x) r[i*8+:8]={(i+1<x),a[i*7+:7]}; end")
core('leb128_decode4', 'packet', 'Decode b=1..4 low bytes of a, require canonical minimal unsigned LEB128 with terminal continuation=0; unused bytes ignored. aux=length. Malformed input faults with result=aux=0.',
     "if(b<1 || b>4) f=1; else begin for(i=0;i<4;i=i+1) if(i<b) begin r[i*7+:7]=a[i*8+:7]; if(a[i*8+7]!=(i+1<b)) f=1; end if(b>1 && ((r>>((b-1)*7))==0)) f=1; if(f) r=0; else x=b; end")

core('walking_pattern32', 'diagnostics', 'a=bit index 0..31, b[0]=0 walking1,1 walking0; result=pattern, aux=next index. Invalid index faults.',
     "if(a>31) f=1; else begin r=32'd1<<a; if(b[0]) r=~r; x=(a+1)&31; end")
core('march_step32', 'diagnostics', 'a=observed word,b=phase0..5,c=address. March C- micro-step: w0,r0w1,r1w0,r0w1,r1w0,r0. result=write data; aux[0]=write,aux[1]=compare,aux[2]=descending,aux[31:3]=c low29. Compare mismatch faults; this is a micro-step, not a RAM controller.',
     "x=(c<<3); if(b>5) f=1; else begin if(b==0) x=x|1; else begin x=x|2; if(b!=5) x=x|1; if(b==3 || b==4) x=x|4; temp=(b==2 || b==4)?32'hffffffff:0; if(a!=temp) f=1; if(b==1 || b==3) r=32'hffffffff; end end")
core('stuck_fault32', 'diagnostics', 'a=observed,b=expected,c=care mask; result=observed0/expected1 bits, aux=observed1/expected0 bits; fault=any mismatch.',
     "r=(~a)&b&c; x=a&(~b)&c; f=|(r|x);")
core('parity_lane32', 'diagnostics', 'result[3:0]=even parity of each byte in a; compare to b[3:0] when c[0]=1, aux=mismatching lanes, fault=any mismatch.',
     "for(i=0;i<4;i=i+1) r[i]=^a[i*8+:8]; if(c[0]) begin x=(r^b)&15; f=|x; end")
core('redundancy_compare32', 'diagnostics', 'result=bitwise majority of a,b,c; aux=bits where replicas disagree; fault=any disagreement. Does not assert TMR physical fault tolerance.',
     "r=(a&b)|(a&c)|(b&c); x=(a^b)|(b^c); f=|x;")
core('range_guard32', 'diagnostics', 'Unsigned a in inclusive [b,c]; result=a if valid else0; aux[0]=below,aux[1]=above,aux[2]=invalid bounds; faults on any violation.',
     "if(b>c) begin x=4; f=1; end else begin x={30'd0,(a>c),(a<b)}; f=|x; if(!f) r=a; end")
core('onehot_guard32', 'diagnostics', 'a must have exactly one bit set unless c[0] permits zero. result=bit index or32 for zero; aux=population count; fault on violation.',
     "r=32; for(i=0;i<32;i=i+1) if(a[i]) begin x=x+1; r=i; end f=(x>1)||((x==0)&&!c[0]);")
core('change_detect32', 'diagnostics', 'Accepted-word change detector: result=a XOR previous, aux=new a. c[31] restarts previous=0.',
     "temp=c[31]?0:state_r[31:0]; r=a^temp; x=a; state_n={32'd0,a};", True)

core('stream_prefix_sum32', 'stream', 'Accepted-beat prefix sum of a modulo2^32; aux=carry on this addition; c[31] restarts sum=0.',
     "temp=c[31]?0:state_r[31:0]; ext={1'b0,temp}+{1'b0,a}; r=ext[31:0]; x={31'd0,ext[32]}; state_n={32'd0,r};", True)
core('stream_running_min32', 'stream', 'Unsigned accepted-beat minimum; aux=number of beats modulo2^32; c[31] starts a new run. First beat always selects a.',
     "temp=c[31]?0:state_r[63:32]; r=(c[31] || !state_r[64] || a<state_r[31:0])?a:state_r[31:0]; x=temp+1; state_n={31'd0,1'b1,x,r};", True)
core('stream_running_max32', 'stream', 'Unsigned accepted-beat maximum; aux=number of beats modulo2^32; c[31] starts a new run.',
     "temp=c[31]?0:state_r[63:32]; r=(c[31] || !state_r[64] || a>state_r[31:0])?a:state_r[31:0]; x=temp+1; state_n={31'd0,1'b1,x,r};", True)
core('stream_delta32', 'stream', 'Accepted-word delta a-previous modulo2^32; aux=previous; c[31] restarts previous=0.',
     "temp=c[31]?0:state_r[31:0]; r=a-temp; x=temp; state_n={32'd0,a};", True)
core('stream_xor_acc32', 'stream', 'Accepted-beat XOR accumulator; aux=previous accumulator; c[31] restarts accumulator=0.',
     "temp=c[31]?0:state_r[31:0]; r=temp^a; x=temp; state_n={32'd0,r};", True)
core('stream_sequence32', 'stream', 'Check accepted a against expected sequence. Expected starts at b after reset or c[31]; every beat next expected=a+1. result=next expected,aux=prior expected,fault=mismatch.',
     "temp=(c[31] || !state_r[32])?b:state_r[31:0]; f=(a!=temp); r=a+1; x=temp; state_n={31'd0,1'b1,r};", True)
core('stream_rising_edges32', 'stream', 'Accepted-word rising bits result=a AND NOT previous; aux=falling bits; c[31] restarts previous=0.',
     "temp=c[31]?0:state_r[31:0]; r=a&~temp; x=(~a)&temp; state_n={32'd0,a};", True)
core('stream_credit32', 'stream', 'Credit ledger: add a then spend b; c[31] resets credit=0. On 33-bit add overflow or insufficient credit, fault and preserve old credit. result=credit,aux=spent (0 on fault).',
     "temp=c[31]?0:state_r[31:0]; ext={1'b0,temp}+{1'b0,a}; if(ext[32] || ext<{1'b0,b}) begin f=1; r=temp; end else begin r=ext[31:0]-b; x=b; end state_n={32'd0,r};", True)

core('event_counter32', 'control', 'Add popcount(a AND b) into saturating event counter; aux=this beat count; fault=saturation. c[31] restarts counter=0.',
     "temp=c[31]?0:state_r[31:0]; for(i=0;i<32;i=i+1) if(a[i]&&b[i]) x=x+1; ext={1'b0,temp}+{1'b0,x}; f=ext[32]; r=f?32'hffffffff:ext[31:0]; state_n={32'd0,r};", True)
core('sticky_event32', 'control', 'Sticky bitmap: result=(previous AND NOT b) OR a; set dominates clear; aux=newly set bits; c[31] restarts previous=0.',
     "temp=c[31]?0:state_r[31:0]; r=(temp&~b)|a; x=r&~temp; state_n={32'd0,r};", True)
core('first_fault32', 'control', 'Latch first nonzero a as fault code and corresponding b timestamp until c[31] restart; result=latched code,aux=timestamp.',
     "if(c[31]) state_n=0; if(state_n[31:0]==0 && a!=0) state_n={b,a}; r=state_n[31:0]; x=state_n[63:32];", True)
core('watermark32', 'control', 'Accepted-word unsigned high watermark; aux=current a; c[31] restarts high=0.',
     "temp=c[31]?0:state_r[31:0]; r=(a>temp)?a:temp; x=a; state_n={32'd0,r};", True)
core('hysteresis32', 'control', 'a=unsigned sample,b=low,c[30:0]=high,c[31]=restart to0. State goes1 when a>=high,0 when a<=low; middle holds. b>=high faults and preserves state. result=state,aux=changed.',
     "temp=c[31]?0:state_r[31:0]; if(b>= {1'b0,c[30:0]}) begin f=1; r=temp; end else begin r=temp; if(a>={1'b0,c[30:0]}) r=1; else if(a<=b) r=0; x=r^temp; end state_n={32'd0,r};", True)
core('debounce_word32', 'control', 'a=candidate word,b=number of identical accepted samples (1..65535),c[31]=restart. result=stable word,aux=current run length capped at65535. Invalid b faults and preserves state. Reset stable=0; qualified candidate replaces stable.',
     "if(c[31]) state_n=0; if(b==0 || b>65535) begin f=1; r=state_n[31:0]; x={16'd0,state_n[79:64]}; end else begin if(a!=state_n[63:32]) begin state_n[63:32]=a; state_n[79:64]=1; end else if(state_n[79:64]!=65535) state_n[79:64]=state_n[79:64]+1; if(state_n[79:64]>=b) state_n[31:0]=a; r=state_n[31:0]; x={16'd0,state_n[79:64]}; end", True)
core('token_bucket32', 'control', 'Accepted-beat tokens: refill a, cost b, capacity c[30:0],c[31]=restart. Saturate refill at capacity; grant if cost fits. result=remaining tokens,aux=granted,fault=denied.',
     "temp=c[31]?0:state_r[31:0]; ext={1'b0,temp}+{1'b0,a}; if(ext>{2'd0,c[30:0]}) ext={2'd0,c[30:0]}; if(ext>={1'b0,b}) begin r=ext[31:0]-b; x=1; end else begin r=ext[31:0]; f=1; end state_n={32'd0,r};", True)
core('round_robin8', 'control', 'a[7:0]=requests,b[7:0]=enable mask,c[31]=restart pointer0. result=onehot grant,aux=grant index or8 if none. Pointer advances only on nonzero grant.',
     "temp=c[31]?0:state_r[31:0]; x=8; for(i=7;i>=0;i=i-1) begin idx=(temp+i)&7; if(a[idx]&&b[idx]) begin r=32'd1<<idx; x=idx; end end if(r!=0) state_n={32'd0,((x+32'd1)&32'd7)}; else state_n={32'd0,temp};", True)

assert len(CORES) == 56
assert len({c['name'] for c in CORES}) == 56
