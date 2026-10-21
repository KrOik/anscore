from pathlib import Path
import sys,tempfile,json,hashlib,random,re
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'bt656_rx.sv'
def xy(f,v,h):return 128|(f<<6)|(v<<5)|(h<<4)|((v^h)<<3)|((f^h)<<2)|((f^v)<<1)|(f^v^h)
def trs(f,v,h):return [255,0,0,xy(f,v,h)]
def fixture(w,l,standard=False):
 data=[];expected=[]
 for f in range(2):
  # Include every vertical blank line of standard field raster. PAL totals 313/312; NTSC 263/262.
  total=(313-f if l==288 else 263-f) if standard else l+3
  blank=total-l
  for n in range(total):
   active=n>=blank
   data+=trs(f,not active,0)
   if active:
    row=[(x*37+n*19+f*71)&255 for x in range(w*2)]
    if w>=4:row[:4]=[255,0,0,171] # Legal arbitrary payload prefix is not a TRS.
    data+=row;expected+=row
   else:data += [128,16,128,16]*(w//2 if standard else w)
   hblank=(280 if l==288 else 268) if standard else 12
   data+=trs(f,not active,1)+[128,16,128,16]*(hblank//4)
 # No trailing bytes after terminating EAV.
 data=data[:-hblank]
 return data,expected
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=1,done_ready=0;
reg[15:0]cfg_width=W,cfg_field_lines=L;reg[7:0]s_data=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_field,m_field_sof,done_valid,frame_error;wire[7:0]m_data,error_code;
bt656_rx #(.MAX_WIDTH(MW),.MAX_FIELD_LINES(ML)) dut(.*);
reg[7:0]src[0:NB-1],exp[0:NP-1];integer i,got=0,cycles=0;reg stalled=0;reg[12:0]held;wire[12:0]token={m_data,m_sof,m_eol,m_last,m_field,m_field_sof};
always @(negedge clk)begin cycles=cycles+1;ce=cycles%17>1;m_ready=cycles%7>1;if(cycles>20000000)$fatal(1,"timeout");end
always @(posedge clk)if(rst_n)begin
 if(stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(!ERR)begin
 if(got>=NP||m_data!==exp[got])$fatal(1,"byte %d",got);
 if(m_sof!==(got==0)||m_eol!==(got%(W*2)==W*2-1)||m_last!==(got==NP-1)||m_field!==(got>=NP/2)||m_field_sof!==(got==0||got==NP/2))$fatal(1,"marker %d",got);
 end got=got+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin
 $readmemh("SRC",src);$readmemh("EXP",exp);repeat(3)tick;rst_n=1;tick;start_valid=1;@(posedge clk);tick;start_valid=0;
 for(i=0;i<NB&&!done_valid;i=i+1)begin s_data=src[i];s_valid=1;s_last=i==NB-1;begin:waitbyte reg ok;ok=0;while(!ok&&!done_valid)begin @(posedge clk);ok=ce&&s_ready;end end tick;end s_valid=0;s_last=0;
 while(!done_valid)tick;
 if(error_code!=ERR||(!ERR&&got!=NP))$fatal(1,"result %h bytes %d",error_code,got);
 repeat(9)tick;if(!done_valid)$fatal(1,"done hold");$display("PASS BT656 bytes %d cycles %d",got,cycles);$finish;end
endmodule'''
def run_case(name,data,pixels,w,l,error=0,mw=720,ml=288):
 with tempfile.TemporaryDirectory(prefix='bt656_rx_') as td:
  d=Path(td);tb=TB
  for token,values in [('SRC',data or [0]),('EXP',pixels or [0])]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  for a,b in [('MW',mw),('ML',ml),('W',w),('L',l),('NB',max(1,len(data))),('NP',max(1,len(pixels))),('ERR',error)]:tb=re.sub(r'\b'+a+r'\b',str(b),tb)
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/(name+'_compile.log'))
  out=execute(['vvp',d/'a.vvp'],ROOT,H/(name+'_simulation.log'),timeout=600);assert 'PASS BT656' in out
 return dict(name=name,bytes=len(data),output_bytes=len(pixels),expected_error=error)
def main():
 cases=[]
 for w,l in [(2,1),(4,3),(16,12),(720,288),(720,240)]:
  data,pix=fixture(w,l,w==720);cases.append(run_case(f'valid_{w}_{l}',data,pix,w,l))
 data,pix=fixture(4,3)
 for bit in range(8):
  bad=data.copy();bad[3]^=1<<bit;cases.append(run_case(f'xy_bit_{bit}',bad,[],4,3,2))
 # first active SAV occurs after three blank lines.
 active=3*(8+16+12);sav=active+3
 bad=data.copy();bad[sav]=xy(1,0,0);cases.append(run_case('wrong_field',bad,[],4,3,3))
 bad=data[:sav+5];cases.append(run_case('truncated_payload',bad,[],4,3,4))
 eav=sav+1+8;bad=data.copy();bad[eav]=0;cases.append(run_case('missing_eav',bad,[],4,3,5))
 for f,v,h in [(1,0,1),(0,1,1),(0,0,0)]:
  bad=data.copy();bad[eav+3]=xy(f,v,h);cases.append(run_case(f'eav_fvh_{f}{v}{h}',bad,[],4,3,5))
 for delta in [-1,1]:
  bad=data.copy();
  if delta<0:del bad[eav-1]
  else:bad.insert(eav,123)
  cases.append(run_case(f'active_length_{delta}',bad,[],4,3,5))
 for w,l,e in [(2,3,5),(6,3,5),(4,2,3),(4,4,3)]:cases.append(run_case(f'length_config_{w}_{l}',data,[],w,l,e))
 for mw,ml in [(1,288),(32767,288),(720,0),(720,32768)]:cases.append(run_case(f'static_{mw}_{ml}',[0],[],4,3,1,mw,ml))
 for w,l in [(1,1),(3,1),(722,1),(2,0),(2,289)]:cases.append(run_case(f'config_{w}_{l}',[0],[],w,l,1))
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=cases),indent=2)+'\n')
 print('PASS BT656',len(cases),'cases')
if __name__=='__main__':main()

