"""Independent four-layout bytes oracle, actual RTL in each direction."""
from pathlib import Path
import sys,tempfile,random,json,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTLS=[HERE/'yuv422_byte_packer.sv',HERE/'yuv422_byte_unpacker.sv']
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in RTLS}
def oracle(words,mode):
 order=[(0,2,1,3),(2,0,3,1),(0,3,1,2),(3,0,2,1)][mode]
 return [v.to_bytes(4,'big')[j] for v in words for j in order]
TB=r"""module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[1:0]cfg_order=MODE;reg[SW-1:0]s_data=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]error_code;wire[MW-1:0]m_data;
NAME #(.WIDTH(WW),.HEIGHT(HH))dut(.*);
reg[SW-1:0]ins[0:NI-1];reg[MW-1:0]outs[0:NO-1];integer cyc=0,i,got=0,rep;reg held_valid=0;reg[MW+2:0]held;
wire[MW+2:0]token={m_sof,m_eol,m_last,m_data};
task tick;begin @(negedge clk);#1;end endtask
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%11<7;if(cyc>3000000)$fatal(1,"timeout");end
always @(posedge clk)if(rst_n)begin
if(held_valid&&(!m_valid||token!==held))$fatal(1,"hold");held_valid=m_valid&&!(ce&&m_ready);held=token;
if(ce&&m_valid&&m_ready)begin
if(m_data!==outs[got%NO])$fatal(1,"data got %h expected %h at %d",m_data,outs[got%NO],got);
if(m_sof!==(got%NO==0)||m_eol!==(got%OROW==OROW-1)||m_last!==(got%NO==NO-1))$fatal(1,"marker");got=got+1;end end
initial begin $readmemh("INPUT",ins);$readmemh("OUTPUT",outs);repeat(3)tick;rst_n=1;tick;
for(rep=0;rep<2;rep=rep+1)begin
cfg_order=MODE;start_valid=1;while(!(ce&&start_ready))tick;@(posedge clk);#1;tick;start_valid=0;cfg_order=MODE^3;
for(i=0;i<NI;i=i+1)begin s_valid=1;s_data=ins[i];s_sof=i==0;s_eol=i%IROW==IROW-1;s_last=i==NI-1;while(!(ce&&s_ready))tick;@(posedge clk);#1;tick;s_valid=0;end
while(!done_valid)tick;if(done_error||error_code||got!=(rep+1)*NO)$fatal(1,"done");repeat(3)tick;if(!done_valid)$fatal(1,"donehold");done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;
end $display("PASS YUV");$finish;end endmodule"""
def run(w,h,mode,pack):
 rng=random.Random(w*100+h*10+mode);words=[rng.getrandbits(32) for _ in range(w*h//2)];words[:2]=[0x0011aaff,0xffee5500] if len(words)>1 else words[:2]
 
 if len(words)>=256:
  for i in range(256):words[i]=(i<<24)|(((i*3+17)&255)<<16)|(((i*5+61)&255)<<8)|((i*7+103)&255)
 by=oracle(words,mode);ins,outs=(words,by) if pack else (by,words);name='yuv422_byte_'+('packer' if pack else 'unpacker')
 with tempfile.TemporaryDirectory(prefix='yuv422_bytes_') as tmp:
  d=Path(tmp);(d/'in.hex').write_text('\n'.join(f'{v:x}' for v in ins));(d/'out.hex').write_text('\n'.join(f'{v:x}' for v in outs))
  tb=TB
  for k,v in dict(NAME=name,MODE=mode,WW=w,HH=h,SW=32 if pack else 8,MW=8 if pack else 32,NI=len(ins),NO=len(outs),IROW=w//2 if pack else w*2,OROW=w*2 if pack else w//2,INPUT=(d/'in.hex').as_posix(),OUTPUT=(d/'out.hex').as_posix()).items():tb=tb.replace(k,str(v))
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a',*RTLS,d/'tb.sv'],HERE,d/'compile.log');out=execute(['vvp',d/'a'],HERE,d/'sim.log',timeout=180);assert 'PASS YUV' in out
 return dict(width=w,height=h,mode=mode,direction='pack' if pack else 'unpack',frames=2,pixels=2*w*h)
def main(kind='all'):
 assert kind in ('all','pack','unpack')
 before=hashes();directions=[True,False] if kind=='all' else [kind=='pack']
 rows=[run(w,h,m,p) for w,h in [(2,1),(16,12),(720,4),(1920,2)] for m in range(4) for p in directions];assert hashes()==before
 filename='evidence.json' if kind=='all' else ('evidence_packer.json' if kind=='pack' else 'evidence_unpacker.json')
 (HERE/filename).write_text(json.dumps(dict(status='PASS',sources=before,cases=rows),indent=2)+'\n');print('PASS YUV422',kind,len(rows),'cases')
if __name__=='__main__':
 import argparse
 ap=argparse.ArgumentParser();ap.add_argument('--kind',choices=['all','pack','unpack'],default='all');main(ap.parse_args().kind)
