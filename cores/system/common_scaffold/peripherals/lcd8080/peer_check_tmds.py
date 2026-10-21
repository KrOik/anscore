"""Read-only independent TMDS review; writes artifacts only alongside this file."""
from test_lcd8080 import HERE,tool,execute
from pathlib import Path
import tempfile,hashlib,json,random,re
OTHER=HERE.parents[1]/'image/tmds_codec'
CONTROL=[0b1101010100,0b0010101011,0b0101010100,0b1010101011]
def encode(byte,rd):
 xor=byte.bit_count()<4 or (byte.bit_count()==4 and (byte&1)!=0)
 q=byte&1;last=q
 for k in range(1,8):
  last=last^((byte>>k)&1)^(not xor);q|=int(last)<<k
 balance=q.bit_count()*2-8
 invert=(not xor) if rd==0 or balance==0 else (rd>0 and balance>0) or (rd<0 and balance<0)
 code=(int(invert)<<9)|(int(xor)<<8)|(q^(255 if invert else 0))
 return code,rd+2*code.bit_count()-10
def vectors():
 rng=random.Random(92383);enc=[];rd=0
 for n in range(768):
  if n%29==0:
   c=(n//29)%4;rd=0;enc.append((c<<8,CONTROL[c],rd))
  else:
   byte=(n if n<256 else rng.randrange(256))&255;code,rd=encode(byte,rd);enc.append((1024|byte,code,rd))
 witnesses={0:[]};todo=[0]
 for current in todo:
  for byte in range(256):
   _,nxt=encode(byte,current)
   if nxt not in witnesses:witnesses[nxt]=witnesses[current]+[byte];todo.append(nxt)
 dec=[];rd=0;sync=False
 def add(code):
  nonlocal rd,sync
  if code in CONTROL:
   out=CONTROL.index(code)<<8;rd=0;sync=True
  else:
   q=(code&255)^(255 if code&512 else 0);byte=q&1
   for k in range(1,8):byte|=(((q>>k)^(q>>(k-1))^(not bool(code&256)))&1)<<k
   expected,nxt=encode(byte,rd)
   if sync and expected==code:out=1024|byte;rd=nxt
   else:out=2048;rd=0;sync=False
  dec.append((code,out,rd,sync))
 add(encode(0x78,0)[0]);add(CONTROL[3])
 for state in witnesses:
  candidates=range(1024) if state==0 else [rng.randrange(1024) for _ in range(24)]
  for candidate in candidates:
   add(CONTROL[0])
   for byte in witnesses[state]:add(encode(byte,rd)[0])
   add(candidate)
   if not sync:add(encode(0x2e,0)[0]) # Lock loss persists until exact control.
 return enc,dec,witnesses
TB=r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,mr=0;reg[10:0]token=0;
wire sr,mv;wire[9:0]symbol;wire signed[5:0]rd;
@DUT@
integer cyc=0,checks=0;reg[11:0]held;
always @(negedge clk)begin cyc=cyc+1;ce=cyc%5!=0;end
task step(input[10:0]word,input[11:0]expected,input integer disparity,input bit lock_);
begin
 @(negedge clk);#1;token=word;sv=1;mr=0;
 begin:a forever begin @(posedge clk);if(ce&&sr)begin #1;disable a;end end end
 @(negedge clk);#1;sv=0;
 if(!mv||payload!==expected||rd!==disparity||locked!==lock_)$fatal(1,"peer expected token/RD/lock check%0d got%h expected%h RD%0d/%0d",checks,payload,expected,rd,disparity);
 held=payload;
 // Offer a different, unaccepted token while blocked, including CE gaps.
 token=~word;sv=1;
 repeat(4)begin @(posedge clk);#1;if(!mv||payload!==held||sr||rd!==disparity||locked!==lock_)$fatal(1,"peer stall changed token/state");end
 @(negedge clk);#1;sv=0;mr=1;
 begin:b forever begin @(posedge clk);if(ce&&mv)begin #1;disable b;end end end
 @(negedge clk);#1;mr=0;checks=checks+1;
end endtask
initial begin repeat(3)@(negedge clk);#1;rst_n=1;
@STEPS@
$display("PASS TMDS PEER @KIND@ checks=%0d CE/stall/state/lock",checks);$finish;end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
ENC='''wire[11:0]payload={2'b0,symbol};wire locked=1;
tmds_encoder d(.clk(clk),.rst_n(rst_n),.ce(ce),.s_data(token[7:0]),.s_de(token[10]),.s_control(token[9:8]),.s_valid(sv),.s_ready(sr),.m_symbol(symbol),.m_valid(mv),.m_ready(mr),.running_disparity(rd));'''
DEC='''wire[7:0]data_;wire de_,err_;wire[1:0]ctrl_;wire locked;
wire[11:0]payload={err_,de_,ctrl_,data_};
tmds_decoder d(.clk(clk),.rst_n(rst_n),.ce(ce),.s_symbol(token[9:0]),.s_valid(sv),.s_ready(sr),.m_data(data_),.m_de(de_),.m_control(ctrl_),.m_error(err_),.m_valid(mv),.m_ready(mr),.running_disparity(rd),.synchronized(locked));'''
def main():
 frozen=json.loads((OTHER/'source_freeze.json').read_text())
 for n,h in frozen.items():assert hashlib.sha256((OTHER/n).read_bytes()).hexdigest()==h,n
 final=json.loads((OTHER/'final_validation.json').read_text());assert final['status']=='PASS'
 for n,h in final['reports'].items():assert hashlib.sha256((OTHER/n).read_bytes()).hexdigest()==h,n
 for n in final['reports']:
  d=json.loads((OTHER/n).read_text());assert d['status']=='PASS'
  for name,sha in d.get('sources',{}).items():assert frozen[name]==sha,(n,name)
 resources=json.loads((OTHER/'synthesis.json').read_text())['profiles']
 for row in resources:
  log=(OTHER/row['log_filename']).read_bytes();assert hashlib.sha256(log).hexdigest()==row['report_sha256']
  stat=log.decode()[log.decode().rfind('=== '+row['module']+' ==='):]
  cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M)}
  assert cells==row['cells'];assert sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)==row['lut_class']
 enc,dec,witnesses=vectors();rows=[]
 for kind,values,dut in [('encoder',[(t,c,r,True) for t,c,r in enc],ENC),('decoder',dec,DEC)]:
  body='\n'.join(f"step(11'h{t:x},12'h{c:x},{r},1'b{int(s)});" for t,c,r,s in values)
  tb=TB.replace('@DUT@',dut).replace('@STEPS@',body).replace('@KIND@',kind)
  with tempfile.TemporaryDirectory(prefix='tmds_peer_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb)
   execute([tool('iverilog'),'-g2012','-s','tb','-o',p/'sim',OTHER/'tmds_encoder.sv',OTHER/'tmds_decoder.sv',p/'tb.sv'],p,p/'compile.log')
   out=execute([tool('vvp'),p/'sim'],p,p/'run.log');(HERE/f'peer_tmds_{kind}.log').write_text(out);assert 'PASS TMDS PEER' in out;print(out)
   rows.append(dict(kind=kind,tokens=len(values),output=out))
 for n,h in frozen.items():assert hashlib.sha256((OTHER/n).read_bytes()).hexdigest()==h
 report=dict(status='PASS',source_freeze_sha256=hashlib.sha256((OTHER/'source_freeze.json').read_bytes()).hexdigest(),reviewed_directory=str(OTHER),frozen_inputs=len(frozen),reports_checked=len(final['reports']),resources=[{k:r[k] for k in ('module','lut_class','dsp','bram9')} for r in resources],independent_tests=rows,reachable_disparities=sorted(witnesses),findings=[],scope='Read-only algorithm, source/report/log binding, natural symbol bit order, CE/stall/RD and decoder lock recovery; no PHY/serializer/board claim.')
 (HERE/'peer_review_tmds.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
