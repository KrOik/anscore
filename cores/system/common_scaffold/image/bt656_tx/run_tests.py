"""Independent complete BT.656 byte-record oracle, including full SD sizes."""
from pathlib import Path
import hashlib,json,sys,tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'bt656_tx.sv'
def xy(f,v,h):return 128|(f<<6)|(v<<5)|(h<<4)|((v^h)<<3)|((f^h)<<2)|((f^v)<<1)|(f^v^h)
def oracle(w,n,total,lb,f1,a0,a1):
 out=bytearray();i=0
 for row in range(total):
  f=int(row>=f1);a=a1 if f else a0;v=int(not(a<=row<a+n))
  out.extend([255,0,0,xy(f,v,0)])
  if not v:
   out.extend(((j*37+11)&255) for j in range(i,i+w*2));i+=w*2
  else:out.extend([128,16]*w)
  out.extend([255,0,0,xy(f,v,1)])
  out.extend([128,16]*((lb-2*w-8)//2))
 assert i==4*w*n and len(out)==total*lb
 return out
TB=r'''module tb;
localparam W=@W@,N=@N@,TL=@TL@,LB=@LB@,F1=@F1@,A0=@A0@,A1=@A1@,NP=W*N*4,NB=TL*LB;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0;wire start_ready;
reg[15:0]cfg_width=W,cfg_field_lines=N,cfg_total_lines=TL,cfg_field1_start=F1,cfg_active0_start=A0,cfg_active1_start=A1;
reg[16:0]cfg_line_bytes=LB;
reg[7:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,s_field=0;wire s_ready;
wire[7:0]m_data,error_code;wire m_valid,m_sof,m_eol,m_last,done_valid,frame_error;reg m_ready=0,done_ready=0;wire[63:0]output_bytes;
bt656_tx #(.MAX_WIDTH(@MW@),.MAX_FIELD_LINES(@MN@))dut(.*);
reg[7:0]expected[0:NB-1];integer cyc=0,i=0,o=0;
reg held=0;reg[10:0]prev;wire[10:0]token={m_sof,m_eol,m_last,m_data};
always @(negedge clk)begin
cyc=cyc+1;ce=cyc%17>2;m_ready=cyc%13<9;
if(cyc>18000000)$fatal(1,"timeout %d %d",i,o);
end
always @(posedge clk)if(rst_n)begin
if(held&&(!m_valid||token!==prev))$fatal(1,"unstable");
held=m_valid&&!(ce&&m_ready);prev=token;
if(ce&&m_valid&&m_ready)begin
if(o>=NB||m_data!==expected[o]||m_sof!==(o==0)||m_eol!==(o%LB==LB-1)||m_last!==(o==NB-1))$fatal(1,"byte mismatch %d got %h expected %h state %d",o,m_data,expected[o],dut.state);
o=o+1;
end
end
initial begin
$readmemh("expected.hex",expected);repeat(3)@(negedge clk);rst_n=1;start_valid=1;
do @(posedge clk);while(!(ce&&start_ready));@(negedge clk);start_valid=0;
cfg_width=1;cfg_field_lines=0;cfg_total_lines=0;cfg_line_bytes=0;cfg_field1_start=0;cfg_active0_start=0;cfg_active1_start=0;
while(!done_valid)begin
s_valid=i<NP;s_data=(i*37+11)&255;s_sof=i==0;s_eol=i%(W*2)==W*2-1;s_last=i==NP-1;s_field=i>=NP/2;
@(posedge clk);if(ce&&s_valid&&s_ready)i=i+1;@(negedge clk);
end
s_valid=0;if(frame_error||error_code||o!=NB||i!=NP||output_bytes!=NB)$fatal(1,"report %d %d %d",o,i,error_code);
repeat(7)begin @(negedge clk);if(!done_valid||output_bytes!=NB)$fatal(1,"DONE unstable");end
$display("PASS BT656 TX W=%0d fieldlines=%0d total=%0d linebytes=%0d bytes=%0d",W,N,TL,LB,NB);$finish;
end
endmodule'''
def run(name,profile,max_width=720,max_lines=288):
 w,n,total,lb,f1,a0,a1=profile;expected=oracle(*profile)
 with tempfile.TemporaryDirectory(prefix='bt656_tx_test_') as t:
  d=Path(t);(d/'expected.hex').write_text(''.join(f'{b:02x}\n' for b in expected))
  tb=TB
  for key,value in dict(W=w,N=n,TL=total,LB=lb,F1=f1,A0=a0,A1=a1,MW=max_width,MN=max_lines).items():tb=tb.replace('@'+key+'@',str(value))
  (d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/(name+'_compile.log'))
  out=execute(['vvp',d/'sim'],d,HERE/(name+'_simulation.log'),timeout=300);assert 'PASS' in out;print(out,flush=True)
 return dict(name=name,width=w,field_lines=n,total_lines=total,line_bytes=lb,field1_start=f1,active0_start=a0,active1_start=a1,payload_bytes=w*n*4,record_bytes=len(expected),oracle_sha256=hashlib.sha256(expected).hexdigest())
def main():
 profiles=[('minimum',(2,1,2,12,1,0,1)),('small_blanking',(4,3,12,32,6,2,8)),('pal_sized_programmable',(720,288,625,1728,312,22,335)),('ntsc_sized_programmable',(720,240,525,1716,262,19,282))]
 rows=[run(name,p) for name,p in profiles]
 (HERE/'main_evidence.json').write_text(json.dumps(dict(status='PASS',source_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows,scope='Programmable line maps; full record comparison. No normative broadcast F/V conformance claim.'),indent=2)+'\n')
if __name__=='__main__':main()
