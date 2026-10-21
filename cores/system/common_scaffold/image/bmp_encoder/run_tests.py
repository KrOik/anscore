"""Actual RTL byte comparison against BMP oracle and Pillow external decoder."""
from pathlib import Path
import sys,tempfile,struct,io,json,hashlib,random
from PIL import Image
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'bmp_encoder.sv'
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def oracle(p,w,h,td):
 stride=(w*3+3)&~3
 raw=b''.join(b''.join(v.to_bytes(3,'big')[::-1] for v in p[y*w:(y+1)*w])+b'\0'*(stride-w*3) for y in (range(h) if td else reversed(range(h))))
 return b'BM'+struct.pack('<IHHI',54+len(raw),0,0,54)+struct.pack('<IiiHHIIiiII',40,w,-h if td else h,1,24,0,len(raw),0,0,0,0)+raw
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,cfg_top_down=TD;
reg[23:0]s_pixel=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;wire[31:0]output_bytes;
bmp_encoder #(.WIDTH(WW),.HEIGHT(HH))dut(.*);
reg[23:0]pixels[0:NN-1];reg[7:0]expected[0:BB-1];integer cyc=0,i,rep,got=0,fd;reg stalled=0;reg[9:0]held;
wire[9:0]token={m_last,m_sof,m_data};
task tick;begin @(negedge clk);#1;end endtask
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%9<6;if(cyc>4000000)$fatal(1,"timeout");end
always @(posedge clk)if(rst_n)begin
if(stalled&&(!m_valid||token!==held))$fatal(1,"unstable output");stalled=m_valid&&!(ce&&m_ready);held=token;
if(ce&&m_valid&&m_ready)begin
if(m_data!==expected[got%BB])$fatal(1,"byte %d got %h expected %h",got,m_data,expected[got%BB]);
if(m_sof!==(got%BB==0)||m_last!==(got%BB==BB-1))$fatal(1,"markers");
if(got<BB)$fwrite(fd,"%c",m_data);got=got+1;end
end
initial begin $readmemh("PFILE",pixels);$readmemh("EFILE",expected);fd=$fopen("OFILE","wb");repeat(3)tick;rst_n=1;tick;
for(rep=0;rep<2;rep=rep+1)begin
start_valid=1;while(!(ce&&start_ready))tick;@(posedge clk);#1;tick;start_valid=0;cfg_top_down=!TD;
for(i=0;i<NN;i=i+1)begin s_valid=1;s_pixel=pixels[i];s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NN-1;
while(!(ce&&s_ready))tick;@(posedge clk);#1;tick;s_valid=0;end
while(!done_valid)tick;
if(done_error||error_code||output_bytes!=BB||got!=(rep+1)*BB)$fatal(1,"DONE");
repeat(3)tick;if(!done_valid)$fatal(1,"done hold");done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;cfg_top_down=TD;
end
$fclose(fd);$display("PASS BMP");$finish;end
endmodule'''
def run_case(w,h,td,seed):
 rng=random.Random(seed);p=[rng.getrandbits(24) for _ in range(w*h)];p[0]=0;p[-1]=0xffffff
 expected=oracle(p,w,h,td)
 with tempfile.TemporaryDirectory(prefix='bmp_encode_') as tmp:
  d=Path(tmp);(d/'p.hex').write_text('\n'.join(f'{v:06x}' for v in p));(d/'e.hex').write_text('\n'.join(f'{v:02x}' for v in expected))
  tb=TB
  for k,v in dict(TD=td,WW=w,HH=h,NN=w*h,BB=len(expected),PFILE=(d/'p.hex').as_posix(),EFILE=(d/'e.hex').as_posix(),OFILE=(d/'o.bmp').as_posix()).items():tb=tb.replace(k,str(v))
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'compile.log')
  out=execute(['vvp',d/'a.vvp'],HERE,d/'sim.log',timeout=180);assert 'PASS BMP' in out
  actual=(d/'o.bmp').read_bytes();assert actual==expected
  im=Image.open(io.BytesIO(actual));im.load();assert im.size==(w,h) and im.tobytes()==b''.join(v.to_bytes(3,'big') for v in p)
 return dict(width=w,height=h,top_down=bool(td),frames=2,pixels=2*w*h,bytes=len(expected),byte_oracle=True,pillow_exact=True)
if __name__=='__main__':
 frozen=hashes();rows=[]
 for w,h in [(1,1),(2,3),(3,4),(4,5),(5,7),(16,12),(31,17),(256,256)]:
  for td in [0,1]:
   row=run_case(w,h,td,w*100+h);rows.append(row);print(json.dumps(row),flush=True)
 assert hashes()==frozen
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n')
