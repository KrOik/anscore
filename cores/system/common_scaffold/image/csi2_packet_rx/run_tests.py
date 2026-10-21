"""Independent matrix ECC, binascii CRC and packet-level CSI-2 receiver tests."""
from pathlib import Path
import binascii, hashlib, itertools, json, random, re, sys, tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'csi2_packet_rx.sv'
PARITY_ROWS=((0,1,2,4,5,7,10,11,13,16,20,21,22,23),
 (0,1,3,4,6,8,10,12,14,17,20,21,22,23),
 (0,2,3,5,6,9,11,12,15,18,20,21,22),
 (1,2,3,7,8,9,13,14,15,19,20,21,23),
 (4,5,6,7,8,9,16,17,18,19,20,22,23),
 (10,11,12,13,14,15,16,17,18,19,21,22,23))
def ecc(header):
 n=int.from_bytes(header,'little')
 return sum((sum((n>>i)&1 for i in row)%2)<<p for p,row in enumerate(PARITY_ROWS))
def reverse(n,bits):return int(f'{n:0{bits}b}'[::-1],2)
def crc(data):
 # Independent mature C polynomial engine, MSB-first CCITT on bit-reversed
 # bytes. Final reflection gives CSI-2 LSB-first 0x8408, no final XOR.
 return reverse(binascii.crc_hqx(bytes(reverse(b,8) for b in data),0xffff),16)
assert crc(b'123456789')==0x6f91 and crc(b'')==0xffff
def header(vc,dt,wc):
 h=bytes([(vc<<6)|dt,wc&255,wc>>8]);return h+bytes([ecc(h)])
def packet(vc,dt,payload=b'',short_data=0):
 if dt<16:return header(vc,dt,short_data)
 return header(vc,dt,len(payload))+payload+crc(payload).to_bytes(2,'little')
def ht(vc,dt,wc,corrected=0):return (((vc<<6|dt)<<16|wc)<<2)|((dt<16)<<1)|corrected
def mt(vc,dt,i,payload):return ((vc<<6|dt)<<10)|((i==0)<<9)|((i==len(payload)-1)<<8)|payload[i]
def pt(h,n=0,calculated=0,received=0,last=1,code=0,header_valid=1):
 return (h<<59)|(n<<43)|(calculated<<27)|(received<<11)|(last<<10)|((code!=0)<<9)|(code<<1)|header_valid
def case(name,wire,headers,pixels,reports,seq=0,error=0,corrected=0,crc_errors=0,frame=0,line=0):
 return dict(name=name,wire=list(wire),headers=headers,pixels=pixels,reports=reports,seq=seq,error=error,corrected=corrected,crc_errors=crc_errors,frame=frame,line=line)
def good(name,vc,dt,payload=b'',short_data=0,corrected=0,wire=None):
 h=ht(vc,dt,len(payload) if dt>=16 else short_data,corrected)
 return case(name,packet(vc,dt,payload,short_data) if wire is None else wire,[h],
 [mt(vc,dt,i,payload) for i in range(len(payload))],
 [pt(h,len(payload),crc(payload) if dt>=16 else 0,crc(payload) if dt>=16 else 0)],corrected=corrected)
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,cfg_check_sequence=0,abort=0;
reg[7:0]s_data=0;reg s_valid=0,s_last=0,h_ready=0,m_ready=0,p_ready=0,done_ready=0;
wire start_ready,s_ready,h_valid,h_short,h_corrected,m_valid,m_first,m_last;
wire[1:0]h_vc,m_vc,p_vc;wire[5:0]h_dt,m_dt,p_dt;wire[15:0]h_word_count;
wire[7:0]m_data,p_error_code,error_code;wire p_valid,p_error,p_header_valid,p_short,p_corrected,p_last;
wire[15:0]p_word_count,p_payload_bytes,p_crc_calculated,p_crc_received;
wire done_valid,done_error,busy;wire[31:0]packet_count,corrected_count,crc_error_count;
wire[3:0]frame_active,line_active;
csi2_packet_rx #(.MAX_WORD_COUNT(LIMIT))dut(.*);
reg[8:0]input_mem[0:INPUT_N-1];reg[25:0]header_mem[0:HEADER_N-1];
reg[17:0]pixel_mem[0:PIXEL_N-1];reg[84:0]report_mem[0:REPORT_N-1];reg[31:0]commands[0:CMD_N-1];
wire[25:0]htoken={h_vc,h_dt,h_word_count,h_short,h_corrected};
wire[17:0]mtoken={m_vc,m_dt,m_first,m_last,m_data};
wire[84:0]ptoken={p_vc,p_dt,p_word_count,p_short,p_corrected,p_payload_bytes,p_crc_calculated,p_crc_received,p_last,p_error,p_error_code,p_header_valid};
integer cyc=0,c=0,i,k,ibase=0,hbase=0,mbase=0,pbase=0,got_h=0,got_m=0,got_p=0,send_count=0;
reg held_h=0,held_m=0,held_p=0;reg[25:0]prev_h;reg[17:0]prev_m;reg[84:0]prev_p;
always @(negedge clk)begin
cyc=cyc+1;ce=cyc%17>2;h_ready=cyc%11<7;m_ready=cyc%13<8;p_ready=cyc%19<11;
if(cyc>20000000)$fatal(1,"timeout case %d state %d byte %d",c,dut.state,i);
end
always @(posedge clk)if(rst_n)begin
 if(held_h&&(!h_valid||htoken!==prev_h))$fatal(1,"header unstable");
 if(held_m&&(!m_valid||mtoken!==prev_m))$fatal(1,"payload unstable");
 if(held_p&&(!p_valid||ptoken!==prev_p))$fatal(1,"report unstable");
 held_h=h_valid&&!(ce&&h_ready);held_m=m_valid&&!(ce&&m_ready);held_p=p_valid&&!(ce&&p_ready);
 prev_h=htoken;prev_m=mtoken;prev_p=ptoken;
 if(ce&&h_valid&&h_ready)begin
  if(got_h>=commands[c*12+1]||htoken!==header_mem[hbase+got_h])$fatal(1,"header case %d %d got %h exp %h",c,got_h,htoken,header_mem[hbase+got_h]);got_h=got_h+1;
 end
 if(ce&&m_valid&&m_ready)begin
  if(got_m>=commands[c*12+2]||mtoken!==pixel_mem[mbase+got_m])$fatal(1,"pixel case %d %d got %h exp %h",c,got_m,mtoken,pixel_mem[mbase+got_m]);got_m=got_m+1;
 end
 if(ce&&p_valid&&p_ready)begin
  if(got_p>=commands[c*12+3]||ptoken!==report_mem[pbase+got_p])$fatal(1,"report case %d %d got %h exp %h",c,got_p,ptoken,report_mem[pbase+got_p]);got_p=got_p+1;
 end
end
task tick;begin @(negedge clk);#1;end endtask
task send_byte;input[8:0]b;begin
 s_valid=1;s_data=b[7:0];s_last=b[8];
 begin:wait_input
 while(1)begin @(posedge clk);if(ce&&s_ready)begin tick;disable wait_input;end end
 end s_valid=0;
end endtask
initial begin
$readmemh("INPUT_FILE",input_mem);$readmemh("HEADER_FILE",header_mem);$readmemh("PIXEL_FILE",pixel_mem);$readmemh("REPORT_FILE",report_mem);$readmemh("CMD_FILE",commands);
repeat(3)tick;rst_n=1;tick;
for(c=0;c<CASES;c=c+1)begin
got_h=0;got_m=0;got_p=0;cfg_check_sequence=commands[c*12+4];start_valid=1;
begin:wait_start while(1)begin @(posedge clk);if(ce&&start_ready)begin tick;disable wait_start;end end end
start_valid=0;cfg_check_sequence=~cfg_check_sequence;
for(i=0;i<commands[c*12];i=i+1)begin
 for(k=0;k<(i+c)%3;k=k+1)tick;
 send_byte(input_mem[ibase+i]);
end
while(!done_valid)tick;
if(got_h!=commands[c*12+1]||got_m!=commands[c*12+2]||got_p!=commands[c*12+3])$fatal(1,"count case %d",c);
if(done_error!==(commands[c*12+5]!=0)||error_code!==commands[c*12+5])$fatal(1,"error case %d got %h expected %h",c,error_code,commands[c*12+5]);
if(packet_count!=got_p||corrected_count!=commands[c*12+6]||crc_error_count!=commands[c*12+7]||frame_active!=commands[c*12+8]||line_active!=commands[c*12+9])$fatal(1,"status case %d",c);
repeat(8)tick;
if(!done_valid||h_valid||m_valid||p_valid||s_ready)$fatal(1,"done not held");
done_ready=1;begin:wait_done while(1)begin @(posedge clk);if(ce&&done_valid)begin tick;disable wait_done;end end end done_ready=0;
ibase=ibase+commands[c*12];hbase=hbase+got_h;mbase=mbase+got_m;pbase=pbase+got_p;
end
$display("CSI2 PASS streams=%d HEADERS=%d PAYLOAD=%d REPORTS=%d CYCLES=%d",CASES,hbase,mbase,pbase,cyc);$finish;
end endmodule'''
def simulate(cases,label='main',limit=4096):
 source_sha=hashlib.sha256(RTL.read_bytes()).hexdigest()
 with tempfile.TemporaryDirectory(prefix='csi2_packet_sim_') as temp:
  d=Path(temp);arrays={'INPUT':[],'HEADER':[],'PIXEL':[],'REPORT':[],'CMD':[]}
  for c in cases:
   arrays['INPUT'] += [(v|(int(i==len(c['wire'])-1)<<8)) for i,v in enumerate(c['wire'])]
   arrays['HEADER']+=c['headers'];arrays['PIXEL']+=c['pixels'];arrays['REPORT']+=c['reports']
   arrays['CMD'] += [len(c['wire']),len(c['headers']),len(c['pixels']),len(c['reports']),c['seq'],c['error'],c['corrected'],c['crc_errors'],c['frame'],c['line'],0,0]
  code=TB.replace('LIMIT',str(limit)).replace('CASES',str(len(cases)))
  for key,values in arrays.items():
   path=d/(key+'.hex');path.write_text('\n'.join(f'{v:x}' for v in values) if values else '0')
   code=code.replace(key+'_FILE',path.as_posix()).replace(key+'_N',str(max(1,len(values))))
  (d/'tb.sv').write_text(code)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim.vvp',RTL,d/'tb.sv'],HERE,HERE/(label+'_compile.log'))
  output=execute(['vvp',d/'sim.vvp'],HERE,HERE/(label+'_simulation.log'),timeout=300)
  assert 'CSI2 PASS' in output,output
 assert source_sha==hashlib.sha256(RTL.read_bytes()).hexdigest()
 row=dict(status='PASS',label=label,source_sha256=source_sha,cases=len(cases),input_bytes=len(arrays['INPUT']),headers=len(arrays['HEADER']),payload_bytes=len(arrays['PIXEL']),reports=len(arrays['REPORT']),names=[c['name'] for c in cases],simulation=output.strip())
 (HERE/(label+'_evidence.json')).write_text(json.dumps(row,indent=2)+'\n');print(output.strip(),flush=True);return row
def build_cases():
 cases=[];rng=random.Random(0xc512)
 for vc in range(4):
  for dt in list(range(8,16))+list(range(16,64)):
   data=bytes(rng.randrange(256) for _ in range((dt*3+vc)%33)) if dt>=16 else b''
   cases.append(good(f'dt_{dt}_vc_{vc}',vc,dt,data,short_data=0x1234+dt))
 # All 32 single flips and all 496 double flips in the physical 4-byte
 # header. Only the 30 protected bits claim SECDED correction.
 for vc in range(4):
  payload=bytes(rng.randrange(256) for _ in range(13));wire=packet(vc,43,payload)
  for bit in range(32):
   broken=bytearray(wire);broken[bit//8]^=1<<(bit%8)
   if bit<30:cases.append(good(f'ecc_single_vc{vc}_b{bit}',vc,43,payload,corrected=1,wire=broken))
   else:cases.append(case(f'reserved_single_vc{vc}_b{bit}',broken[:4],[],[],[pt(0,code=3,header_valid=0)],error=3))
  for a,b in itertools.combinations(range(32),2):
   broken=bytearray(wire[:4]);broken[a//8]^=1<<(a%8);broken[b//8]^=1<<(b%8)
   err=3 if max(a,b)>=30 else 2
   cases.append(case(f'ecc_double_vc{vc}_{a}_{b}',broken,[],[],[pt(0,code=err,header_valid=0)],error=err))
 # Every payload bit and every transmitted CRC bit checked with independent
 # received CRC; provisional payload must exactly match the corrupt bytes.
 payload=bytes(range(32));wire=packet(2,43,payload);h=ht(2,43,32)
 for bit in range(32*8+16):
  broken=bytearray(wire);broken[4+bit//8]^=1<<(bit%8)
  data=bytes(broken[4:-2]);calc=crc(data);received=int.from_bytes(broken[-2:],'little')
  cases.append(case(f'payload_or_crc_flip_{bit}',broken,[h],[mt(2,43,i,data) for i in range(len(data))],[pt(h,len(data),calc,received,code=8)],error=8,crc_errors=1))
 for vc in range(4):
  for dt in range(4,8):
   h=ht(vc,dt,0x1532);cases.append(case(f'reserved_short_{vc}_{dt}',packet(vc,dt,short_data=0x1532),[],[],[pt(h,code=6)],error=6))
 # Truncate at every byte, including the zero-length long-packet CRC.
 for length in [0,1,7,32]:
  payload=bytes(range(length));wire=packet(1,43,payload);h=ht(1,43,length)
  for n in range(1,len(wire)):
   cut=wire[:n];accepted=max(0,min(length,n-4));pixels=[mt(1,43,i,payload) for i in range(accepted)]
   if n<4:headers=[];report=pt(0,code=4,header_valid=0)
   else:
    headers=[h];calc=crc(payload[:accepted])
    received=wire[-2] if n==len(wire)-1 else 0
    report=pt(h,accepted,calc,received,code=4)
   cases.append(case(f'truncated_n{length}_at{n}',cut,headers,pixels,[report],error=4))
 for length in [0,1,2,255,256,4095,4096]:
  cases.append(good(f'word_count_{length}',3,42,bytes(rng.randrange(256) for _ in range(length))))
 h=ht(0,43,4097);cases.append(case('word_count_overflow',header(0,43,4097),[],[],[pt(h,code=5)],error=5))
 # Four independent VC state machines, line packets optional. Generic short
 # packets are deliberately placed outside frames in strict mode.
 seq=[]
 for vc in range(4):seq.append((vc,8,b'',999))
 for vc in range(4):seq.append((vc,0,b'',0x200+vc))
 for line in range(3):
  for vc in range(4):seq.append((vc,2,b'',line+1))
  for vc in range(4):seq.append((vc,43,bytes([vc,line,9,12,255]),0))
  for vc in reversed(range(4)):seq.append((vc,3,b'',line+1))
 for vc in reversed(range(4)):seq.append((vc,1,b'',0x200+vc))
 cases.append(mixed('interleaved_four_vc_frames',seq,seq_check=1))
 # CRC error is packet-local: continue to a valid packet using trusted WC.
 seq=[(0,43,b'bad crc',0),(3,8,b'',0x3421),(2,43,b'healthy after crc',0)]
 cases.append(mixed('crc_continues_at_trusted_boundary',seq,bad_crc_index=0))
 # Long streams, every VC/DT, no reset required between accepted commands.
 seq=[(rng.randrange(4),rng.randrange(16,64),bytes(rng.randrange(256) for _ in range(rng.randrange(41))),0) for _ in range(200)]
 cases.append(mixed('long_mixed_200_packets',seq))
 # Illegal FS/FE/LS/LE sequences and mismatched associated numbers.
 patterns=[[(0,1,0)],[(0,2,1)],[(0,3,1)],[(0,0,10),(0,0,10)],
 [(0,0,10),(0,1,11)],[(0,0,10),(0,2,1),(0,1,10)],
 [(0,0,10),(0,2,1),(0,2,2)],[(0,0,10),(0,2,1),(0,3,2)],
 [(0,0,10),(1,1,10)],[(0,0,10),(0,3,0)]]
 for index,pattern in enumerate(patterns):
  seq=[(vc,dt,b'',number) for vc,dt,number in pattern]
  c=mixed('sequence_error_'+str(index),seq,seq_check=1)
  h=c['headers'][-1];last=c['reports'][-1];c['reports'][-1]=(last&~((1<<11)-1))|(1<<10)|(1<<9)|(7<<1)|1;c['error']=7
  # Track only successful prefix events, not the rejected terminal event.
  for vc,dt,n in pattern[:-1]:
   if dt==0:c['frame']|=1<<vc
   if dt==1:c['frame']&=~(1<<vc)
   if dt==2:c['line']|=1<<vc
   if dt==3:c['line']&=~(1<<vc)
  cases.append(c)
 return cases
def mixed(name,seq,seq_check=0,bad_crc_index=-1):
 wire=bytearray();headers=[];pixels=[];reports=[]
 for index,(vc,dt,payload,number) in enumerate(seq):
  b=bytearray(packet(vc,dt,payload,number));h=ht(vc,dt,len(payload) if dt>=16 else number)
  if index==bad_crc_index:b[-1]^=1
  wire+=b;headers.append(h);pixels.extend(mt(vc,dt,i,payload) for i in range(len(payload)))
  reports.append(pt(h,len(payload),crc(payload) if dt>=16 else 0,(crc(payload)^(256 if index==bad_crc_index else 0)) if dt>=16 else 0,last=index==len(seq)-1,code=8 if index==bad_crc_index else 0))
 return case(name,wire,headers,pixels,reports,seq=seq_check,error=8 if bad_crc_index>=0 else 0,crc_errors=int(bad_crc_index>=0))
if __name__=='__main__':simulate(build_cases())
