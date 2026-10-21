from pathlib import Path
import sys,tempfile,json,hashlib,random,re
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'dvp_rx.sv'
def replicated(v):
 r=(v>>11)&31;g=(v>>5)&63;b=v&31
 return ((r<<3|r>>2)<<16)|((g<<2|g>>4)<<8)|(b<<3|b>>2)
def wave(w,h,mode=0,be=False,vpol=True,hpol=True,simultaneous=False,gaps=True,pixel_values=None):
 rng=random.Random(934+w+h+mode);pixels=list(pixel_values) if pixel_values is not None else [rng.randrange(65536 if mode else 256) for _ in range(w*h)];values=[replicated(v) for v in pixels] if mode else pixels
 out=[]
 def emit(v,h,d=0,sv=1):out.append((sv<<10)|(int(v if vpol else not v)<<9)|(int(h if hpol else not h)<<8)|d)
 for j in range(5):emit(0,j%2,37)
 for _ in range(3):emit(1,0)
 emit(0,0)
 for y in range(h):
  for x in range(w):
   v=pixels[y*w+x];bs=v.to_bytes(2,'big' if be else 'little') if mode else bytes([v])
   for b in bs:
    if gaps and rng.randrange(7)==0:emit(1,1,255,0)
    emit(0,1,b)
  if simultaneous and y==h-1:emit(1,0)
  else:
   emit(0,0)
   for _ in range(3 if gaps else 15):emit(0,0)
 if not simultaneous:emit(1,0)
 for _ in range(3):emit(1,0)
 return out,values
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0;reg[15:0]cfg_width=WW,cfg_height=HH;reg cfg_mode=MODE,cfg_big_endian=BE,cfg_vsync_active_high=VP,cfg_href_active_high=HP;
reg sample_valid=0,vsync=0,href=0;reg[7:0]data=0;wire start_ready,done_valid,frame_error;wire[7:0]error_code;wire[15:0]image_width,image_height;wire image_mode;
wire[23:0]m_pixel;wire m_valid,m_sof,m_eol,m_last;reg m_ready=1,done_ready=0;
dvp_rx #(.MAX_WIDTH(MW),.MAX_HEIGHT(MH),.FIFO_DEPTH(FD))dut(.*);
reg[10:0]waveform[0:NW-1];reg[23:0]expected[0:NP-1];integer i,cycles=0,got=0;reg heldvalid=0;reg[26:0]held;
always @(posedge clk)begin cycles=cycles+1;if(cycles>3000000)$fatal(1,"timeout %d",dut.state);
 if(rst_n&&!ERR)begin
 if(heldvalid&&(!m_valid||{m_pixel,m_sof,m_eol,m_last}!==held))$fatal(1,"hold");heldvalid=m_valid&&!(ce&&m_ready);held={m_pixel,m_sof,m_eol,m_last};
 if(ce&&m_valid&&m_ready)begin if(got>=NP||m_pixel!==expected[got]||m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1))$fatal(1,"pixel %d actual %h expected %h",got,m_pixel,expected[got]);got=got+1;end
 end
end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin $readmemh("WAVE",waveform);$readmemh("EXPECT",expected);repeat(3)tick;rst_n=1;tick;start_valid=1;tick;start_valid=0;cfg_width=1;cfg_height=1;cfg_mode=!MODE;cfg_big_endian=!BE;cfg_vsync_active_high=!VP;cfg_href_active_high=!HP;
 for(i=0;i<NW;i=i+1)begin
 {sample_valid,vsync,href,data}=waveform[i];
 ce=FLOW?i%13>1:1;m_ready=FLOW?i%7>1:1;tick;
 end sample_valid=0;ce=1;m_ready=1;
 while(!done_valid)tick;
 if(frame_error!=(ERR!=0)||error_code!=ERR||(!ERR&&(got!=NP||image_width!=WW||image_height!=HH||image_mode!=MODE)))$fatal(1,"outcome err %h expected %h got %d",error_code,ERR,got);
 repeat(5)tick;if(!done_valid)$fatal(1,"donehold");$display("PASS DVP pixels=%d cycles=%d",got,cycles);$finish;end
endmodule'''
def run_case(name,w,h,mode=0,be=False,vpol=True,hpol=True,flow=True,simultaneous=False,gaps=True,error=0,custom=None,depth=1024,mw=640,mh=480):
 samples,pixels=wave(w,h,mode,be,vpol,hpol,simultaneous,gaps) if custom is None else custom
 with tempfile.TemporaryDirectory(prefix='dvp_rx_test_') as td:
  d=Path(td);tb=TB
  for token,seq in [('WAVE',samples),('EXPECT',pixels or [0])]:
   f=d/(token+'.hex');f.write_text('\n'.join(f'{v:x}' for v in seq));tb=tb.replace('"'+token+'"','"'+f.as_posix()+'"')
  for key,value in dict(WW=w,HH=h,MODE=mode,BE=int(be),VP=int(vpol),HP=int(hpol),NW=len(samples),NP=max(1,len(pixels)),ERR=error,FLOW=int(flow),FD=depth,MW=mw,MH=mh).items():tb=re.sub(r'\b'+key+r'\b',str(value),tb)
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/(name+'_compile.log'));out=execute(['vvp',d/'a.vvp'],ROOT,H/(name+'_simulation.log'),timeout=180);assert 'PASS DVP' in out
 return dict(name=name,width=w,height=h,mode=mode,big_endian=be,vsync_active_high=vpol,href_active_high=hpol,pixels=len(pixels),expected_error=error)
def main():
 rows=[]
 for mode in [0,1]:
  for be in [False,True]:
   for vp,hp in [(True,True),(False,False),(False,True),(True,False)]:rows.append(run_case(f'main_{mode}_{be}_{vp}_{hp}',16,12,mode,be,vp,hp,simultaneous=be))
 for w,h in [(320,240),(640,480)]:
  for mode in [0,1]:rows.append(run_case(f'camera_{w}_{h}_{mode}',w,h,mode,flow=False,gaps=False))
 report=dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows);(H/'evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
