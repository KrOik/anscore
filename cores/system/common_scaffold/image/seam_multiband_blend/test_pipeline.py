"""Complete DP-mask plus Laplacian-frame independent numerical composition."""
from pathlib import Path
import hashlib,importlib.util,json,sys,tempfile
import numpy as np
HERE=Path(__file__).resolve().parent
PACKAGE=HERE.parents[1]
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute

def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
seam_ref=load('seam_numerical_reference',PACKAGE/'image/seam_find/test_seam.py')
blend_ref=load('multiband_numerical_reference',PACKAGE/'image/multiband_blend/test_multiband.py')
SOURCES=[PACKAGE/'image/seam_find/seam_find.sv',PACKAGE/'image/multiband_blend/multiband_blend.sv',HERE/'seam_multiband_blend.sv']

def golden(a,b,d,g,f,l):
 cost,path=seam_ref.shortest(seam_ref.costs(a,b,g),d)
 mask,_=seam_ref.mask_for(a.shape,path,d,f)
 return blend_ref.model(a,b,mask,l),mask,cost,path

def run(label,a,b,d,g,f,l,replays=1):
 h,w=a.shape;out,mask,cost,path=golden(a,b,d,g,f,l)
 cv=blend_ref.cvmodel(a,b,mask,l);cv_difference=int(np.max(np.abs(out.astype(int)-cv.astype(int))));assert cv_difference<=1
 init='\n'.join(f"p[{i}]=16'h{x:02x}{y:02x};e[{i}]=11'h{((i==w*h-1)<<10)|((i%w==w-1)<<9)|((i==0)<<8)|int(z):03x};m[{i}]=8'd{v};" for i,(x,y,z,v) in enumerate(zip(a.flat,b.flat,out.flat,mask.flat)))
 packed=sum(x<<(i*6) for i,x in enumerate(path))
 tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,cfg_valid=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[5:0]cfg_width=WW,cfg_height=HH,cfg_feather=FF;reg cfg_horizontal=DD;reg[7:0]cfg_gradient_weight=GG;reg[1:0]cfg_levels=LL;
 reg[7:0]s_a=0,s_b=0;
 wire cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;
 wire[7:0]m_data,error_code;wire[191:0]seam_coordinates;wire[5:0]seam_length;wire[31:0]total_cost;
 seam_multiband_blend dut(.*);
 reg[15:0]p[0:NN-1];reg[10:0]e[0:NN-1];reg[7:0]m[0:NN-1];
 reg[10:0]held;reg stalled=0;integer cycles=0,i,r,got=0,replayed=0;
 wire[10:0]token={m_last,m_eol,m_sof,m_data};
 localparam[191:0]PATH=192'hPP;localparam[31:0]COST=CC;
 always @(negedge clk)begin cycles=cycles+1;ce=cycles%13!=0&&cycles%13!=1;m_ready=cycles%7<4;if(cycles>3000000)$fatal(1,"timeout top=%d seam=%d blend=%d",dut.state,dut.seam.state,dut.blend.state);end
 always @(posedge clk)if(rst_n)begin
  if(stalled&&(!m_valid||token!==held))$fatal(1,"unstable output");
  stalled=m_valid&&!(ce&&m_ready);held=token;
  if(ce&&m_valid&&m_ready)begin if(got>=NN||token!==e[got])$fatal(1,"pixel %d got=%h expected=%h",got,token,e[got]);got=got+1;end
  if(ce&&dut.replay_valid&&dut.bs_ready)begin
   if(replayed>=NN||dut.pair_q!==p[replayed]||dut.sm_mask!==m[replayed])$fatal(1,"RAM-mask replay alignment %d",replayed);
   replayed=replayed+1;
  end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin
 INIT
 repeat(3)tick;rst_n=1;while(!cfg_ready)tick;cfg_valid=1;tick;cfg_valid=0;
 while(!cfg_done&&!cfg_error)tick;if(cfg_error)$fatal(1,"cfg");
 for(r=0;r<RR;r=r+1)begin
  got=0;replayed=0;while(!start_ready)tick;start_valid=1;tick;start_valid=0;
  cfg_width=0;cfg_height=0;cfg_feather=63;cfg_horizontal=!DD;cfg_gradient_weight=255;cfg_levels=0;
  for(i=0;i<NN;i=i+1)begin
   {s_a,s_b}=p[i];s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NN-1;
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  end
  while(!done_valid)tick;
  if(done_error||error_code||got!=NN||replayed!=NN||seam_coordinates!==PATH||total_cost!==COST||seam_length!=LEN)$fatal(1,"completion path=%h cost=%d code=%h",seam_coordinates,total_cost,error_code);
  abort=1;repeat(7)begin tick;if(!done_valid||done_error||error_code||seam_coordinates!==PATH||total_cost!==COST)$fatal(1,"held DONE late abort");end abort=0;
  while(!ce)tick;done_ready=1;tick;done_ready=0;tick;
 end
 $display("PIPELINE PASS");$finish;end endmodule'''
 for k,v in [('WW',w),('HH',h),('FF',f),('DD',int(d)),('GG',g),('LL',l),('NN',w*h),('PP',f'{packed:x}'),('CC',cost),('LEN',len(path)),('RR',replays),('INIT',init)]:tb=tb.replace(k,str(v))
 with tempfile.TemporaryDirectory(prefix='seam_multiband_') as td:
  td=Path(td);(td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
  assert 'PIPELINE PASS' in execute(['vvp',td/'sim'],td,td/'run.log',timeout=300)
 report=dict(label=label,width=w,height=h,horizontal=d,gradient_weight=g,feather=f,levels=l,replays=replays,
             path=list(path),total_cost=cost,opencv_blend_max_byte_difference=cv_difference,status='PASS')
 print(report,flush=True);return report

def main():
 frozen={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 rng=np.random.default_rng(7981);reports=[]
 for w,h,d,g,f,l,r in [(1,1,False,0,0,2,2),(1,7,False,255,3,3,1),(7,1,True,7,32,3,1),
                         (7,5,False,2,2,2,2),(17,9,True,0,0,3,1),(31,17,False,15,6,3,1),(32,32,True,255,32,3,1)]:
  a=rng.integers(0,256,(h,w),dtype=np.uint8);b=rng.integers(0,256,(h,w),dtype=np.uint8)
  reports.append(run('random',a,b,d,g,f,l,r))
 a=np.zeros((12,9),np.uint8);b=np.full_like(a,200);curve=[3,3,4,4,3,2,2,3,4,5,5,4]
 for y,x in enumerate(curve):b[y,x]=0
 reports.append(run('curved_seam_actual_multiband',a,b,False,0,2,3))
 assert reports[-1]['path']==curve
 assert frozen=={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',cases=reports,sources=frozen,
  scope='Actual DP mask, synchronous A/B replay alignment and complete Laplacian pyramid output, exact independent numerical composition',board=False),indent=2)+'\n')

if __name__=='__main__':main()
