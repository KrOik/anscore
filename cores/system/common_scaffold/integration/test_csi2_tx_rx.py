"""Actual legacy CSI-2 byte TX -> RX, multiple packets in one session."""
import binascii,hashlib,random,tempfile
from pathlib import Path
from tooling import PACKAGE,ROOT,evidence_dir,execute,write_json
PARITY=((0,1,2,4,5,7,10,11,13,16,20,21,22,23),(0,1,3,4,6,8,10,12,14,17,20,21,22,23),(0,2,3,5,6,9,11,12,15,18,20,21,22),(1,2,3,7,8,9,13,14,15,19,20,21,23),(4,5,6,7,8,9,16,17,18,19,20,22,23),(10,11,12,13,14,15,16,17,18,19,21,22,23))
def rev(v,n):return int(f'{v:0{n}b}'[::-1],2)
def crc(payload):return rev(binascii.crc_hqx(bytes(rev(b,8) for b in payload),65535),16)
def wirepacket(vc,dt,value,payload):
 h=bytes([(vc<<6)|dt,value&255,value>>8]);v=int.from_bytes(h,'little')
 ecc=sum((sum((v>>b)&1 for b in row)%2)<<i for i,row in enumerate(PARITY))
 return h+bytes([ecc])+(payload+crc(payload).to_bytes(2,'little') if dt>=16 else b'')
assert crc(b'123456789')==0x6f91
TB=r'''module tb;
localparam NC=@NC@,NB=@NB@,NP=@NP@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,abort=0,tx_start=0,rx_start=0;
reg[1:0]cfg_vc=0;reg[5:0]cfg_dt=0;reg[15:0]cfg_word_count=0;
reg[7:0]tx_s_data=0;reg tx_s_valid=0,tx_s_last=0;
wire tx_start_ready,tx_s_ready,tx_m_valid,tx_m_ready,tx_m_sof,tx_m_last;
wire[7:0]tx_m_data,tx_error_code;wire tx_done,tx_error,tx_busy;reg tx_done_ready=0;wire[31:0]tx_bytes;
csi2_packet_tx tx(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(tx_start),.start_ready(tx_start_ready),.cfg_vc(cfg_vc),.cfg_dt(cfg_dt),.cfg_word_count(cfg_word_count),.abort(abort),.s_data(tx_s_data),.s_valid(tx_s_valid),.s_last(tx_s_last),.s_ready(tx_s_ready),.m_data(tx_m_data),.m_valid(tx_m_valid),.m_ready(tx_m_ready),.m_sof(tx_m_sof),.m_last(tx_m_last),.done_valid(tx_done),.done_ready(tx_done_ready),.done_error(tx_error),.error_code(tx_error_code),.busy(tx_busy),.output_bytes(tx_bytes));
wire rx_start_ready,rx_s_ready,h_valid,h_short,h_corrected,m_valid,m_first,m_last,p_valid,p_error,p_header_valid,p_short,p_corrected,p_last,rx_done,rx_error,rx_busy;
reg h_ready=0,m_ready=0,p_ready=0,rx_done_ready=0;
wire[1:0]h_vc,m_vc,p_vc;wire[5:0]h_dt,m_dt,p_dt;wire[15:0]h_word_count,p_word_count,p_payload_bytes,p_crc_calculated,p_crc_received;
wire[7:0]m_data,p_error_code,rx_error_code;wire[31:0]packet_count,corrected_count,crc_error_count;wire[3:0]frame_active,line_active;
reg link_gate=0;integer ci=0,wi=0,pi=0,hi=0,ri=0,cyc=0;
assign tx_m_ready=rx_s_ready&&link_gate;
csi2_packet_rx #(.MAX_WORD_COUNT(65535))rx(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(rx_start),.start_ready(rx_start_ready),.cfg_check_sequence(1'b1),.abort(abort),.s_data(tx_m_data),.s_valid(tx_m_valid&&link_gate),.s_last(tx_m_last&&ci==NC-1),.s_ready(rx_s_ready),.h_valid(h_valid),.h_ready(h_ready),.h_vc(h_vc),.h_dt(h_dt),.h_word_count(h_word_count),.h_short(h_short),.h_corrected(h_corrected),.m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),.m_first(m_first),.m_last(m_last),.m_vc(m_vc),.m_dt(m_dt),.p_valid(p_valid),.p_ready(p_ready),.p_error(p_error),.p_error_code(p_error_code),.p_header_valid(p_header_valid),.p_vc(p_vc),.p_dt(p_dt),.p_word_count(p_word_count),.p_short(p_short),.p_corrected(p_corrected),.p_payload_bytes(p_payload_bytes),.p_crc_calculated(p_crc_calculated),.p_crc_received(p_crc_received),.p_last(p_last),.done_valid(rx_done),.done_ready(rx_done_ready),.done_error(rx_error),.error_code(rx_error_code),.busy(rx_busy),.packet_count(packet_count),.corrected_count(corrected_count),.crc_error_count(crc_error_count),.frame_active(frame_active),.line_active(line_active));
reg[23:0]desc[0:NC-1];reg[7:0]inputs[0:NP-1],wirebytes[0:NB-1];reg[25:0]headers[0:NC-1];reg[17:0]pixels[0:NP-1];reg[84:0]reports[0:NC-1];
wire[25:0]htoken={h_vc,h_dt,h_word_count,h_short,h_corrected};
wire[17:0]mtoken={m_vc,m_dt,m_first,m_last,m_data};
wire[84:0]ptoken={p_vc,p_dt,p_word_count,p_short,p_corrected,p_payload_bytes,p_crc_calculated,p_crc_received,p_last,p_error,p_error_code,p_header_valid};
reg heldtx=0,heldh=0,heldm=0,heldp=0;reg[9:0]prevtx;reg[25:0]prevh;reg[17:0]prevm;reg[84:0]prevp;
integer localwire=0,plen=0,sendi=0,ibase=0,expected_len;
always @(negedge clk)begin
cyc=cyc+1;ce=cyc%19>3;link_gate=cyc%11<8;h_ready=cyc%13<6;m_ready=cyc%17<9;p_ready=cyc%23<11;
if(cyc>3000000)$fatal(1,"timeout ci %d tx %d rx %d",ci,tx.state,rx.state);
end
always @(posedge clk)if(rst_n)begin
if(heldtx&&(!tx_m_valid||{tx_m_sof,tx_m_last,tx_m_data}!==prevtx))$fatal(1,"TX unstable");
if(heldh&&(!h_valid||htoken!==prevh))$fatal(1,"header unstable");
if(heldm&&(!m_valid||mtoken!==prevm))$fatal(1,"pixel unstable");
if(heldp&&(!p_valid||ptoken!==prevp))$fatal(1,"report unstable");
heldtx=tx_m_valid&&!(ce&&tx_m_ready);prevtx={tx_m_sof,tx_m_last,tx_m_data};
heldh=h_valid&&!(ce&&h_ready);prevh=htoken;
heldm=m_valid&&!(ce&&m_ready);prevm=mtoken;
heldp=p_valid&&!(ce&&p_ready);prevp=ptoken;
if(ce)begin
if(tx_m_valid&&tx_m_ready)begin
if(wi>=NB||tx_m_data!==wirebytes[wi]||tx_m_sof!==(localwire==0)||tx_m_last!==(localwire==expected_len-1))$fatal(1,"wire mismatch %d packet %d byte %d",wi,ci,localwire);
wi=wi+1;localwire=localwire+1;
end
if(h_valid&&h_ready)begin if(hi>=NC||htoken!==headers[hi])$fatal(1,"header %d",hi);hi=hi+1;end
if(m_valid&&m_ready)begin if(pi>=NP||mtoken!==pixels[pi])$fatal(1,"payload %d",pi);pi=pi+1;end
if(p_valid&&p_ready)begin if(ri>=NC||ptoken!==reports[ri])$fatal(1,"report %d got %h expected %h",ri,ptoken,reports[ri]);ri=ri+1;end
end
end
initial begin
$readmemh("desc.hex",desc);$readmemh("input.hex",inputs);$readmemh("wire.hex",wirebytes);$readmemh("header.hex",headers);$readmemh("pixel.hex",pixels);$readmemh("report.hex",reports);
repeat(3)@(negedge clk);rst_n=1;rx_start=1;
do @(posedge clk);while(!(ce&&rx_start_ready));@(negedge clk);rx_start=0;
for(ci=0;ci<NC;ci=ci+1)begin
{cfg_word_count,cfg_vc,cfg_dt}=desc[ci];plen=cfg_dt>=16?cfg_word_count:0;expected_len=cfg_dt>=16?cfg_word_count+6:4;localwire=0;sendi=0;tx_start=1;
do @(posedge clk);while(!(ce&&tx_start_ready));@(negedge clk);tx_start=0;cfg_dt=7;cfg_word_count=0;cfg_vc=3;
while(!tx_done)begin
tx_s_data=inputs[ibase+sendi];tx_s_valid=sendi<plen;tx_s_last=sendi==plen-1;
@(posedge clk);if(ce&&tx_s_valid&&tx_s_ready)sendi=sendi+1;@(negedge clk);
end
tx_s_valid=0;if(tx_error||tx_error_code||tx_bytes!=expected_len||localwire!=expected_len)$fatal(1,"TX report %d",ci);
repeat(3)@(negedge clk);tx_done_ready=1;do @(posedge clk);while(!ce);@(negedge clk);tx_done_ready=0;ibase=ibase+plen;
end
wait(rx_done);@(negedge clk);
if(rx_error||rx_error_code||packet_count!=NC||corrected_count||crc_error_count||frame_active||line_active||wi!=NB||hi!=NC||ri!=NC||pi!=NP)$fatal(1,"final counters");
repeat(5)@(negedge clk);if(!rx_done)$fatal(1,"RX DONE hold");
$display("PASS actual CSI2 TX->RX packets=%0d wirebytes=%0d payload=%0d",NC,NB,NP);$finish;
end
endmodule'''
def main():
 rng=random.Random(20951);packets=[]
 # Interleave all four open frames, with line start/end pairs and two lines.
 for vc in range(4):packets.append((vc,0,101+vc,b''))
 for line in range(2):
  for vc in range(4):
   packets.append((vc,2,line+1,b''))
   n=[0,1,35,4096][vc] if line==0 else [9,32,127,1024][vc]
   payload=bytes(rng.randrange(256) for _ in range(n));packets.append((vc,0x2b+vc%2,n,payload))
   packets.append((vc,3,line+1,b''))
 for vc in range(4):packets.append((vc,8+vc,0x1200+vc,b''));packets.append((vc,1,101+vc,b''))
 stream=b'';inputs=b'';descs=[];headers=[];pixels=[];reports=[]
 for index,(vc,dt,value,data) in enumerate(packets):
  stream+=wirepacket(vc,dt,value,data);inputs+=data;descs.append((value<<8)|(vc<<6)|dt)
  h=(((vc<<6|dt)<<16|value)<<2)|((dt<16)<<1);headers.append(h)
  pixels.extend(((vc<<6|dt)<<10)|((i==0)<<9)|((i==len(data)-1)<<8)|b for i,b in enumerate(data))
  check=crc(data) if dt>=16 else 0
  reports.append((h<<59)|(len(data)<<43)|(check<<27)|(check<<11)|((index==len(packets)-1)<<10)|1)
 sources=[PACKAGE/'image/csi2_packet_tx/csi2_packet_tx.sv',PACKAGE/'image/csi2_packet_rx/csi2_packet_rx.sv']
 hashes={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
 folder=evidence_dir('csi2_tx_rx')
 with tempfile.TemporaryDirectory(prefix='csi2_tx_rx_') as tmp:
  d=Path(tmp)
  for name,values,width in [('desc',descs,6),('input',inputs,2),('wire',stream,2),('header',headers,7),('pixel',pixels,5),('report',reports,22)]:
   (d/(name+'.hex')).write_text(''.join(f'{v:0{width}x}\n' for v in values))
  (d/'tb.sv').write_text(TB.replace('@NC@',str(len(packets))).replace('@NB@',str(len(stream))).replace('@NP@',str(len(inputs))))
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*sources,d/'tb.sv'],ROOT,folder/'compile.log')
  out=execute(['vvp',d/'sim'],d,folder/'simulation.log',timeout=180);assert 'PASS' in out
 assert hashes=={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
 write_json(folder/'results.json',dict(status='PASS',sources=hashes,packets=len(packets),wire_bytes=len(stream),payload_bytes=len(inputs),virtual_channels=4,frames=4,lines=8,crc_kat='6f91',scope='Real TX->RX multi-packet session. FS/LS/long/LE/FE, generic short, independent byte/ECC/CRC and full metadata/payload/report oracle, CE/backpressure/hold/cfgcapture/DONE. No D-PHY, board or routed timing claim.',board_tested=False))
 print(folder,flush=True)
if __name__=='__main__':main()
