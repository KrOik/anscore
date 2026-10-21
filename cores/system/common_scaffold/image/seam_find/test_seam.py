"""Independent shortest-path and exhaustive oracle, actual raster-mask RTL."""
from pathlib import Path
import hashlib,itertools,json,sys,tempfile
import cv2
import numpy as np
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute

def costs(a,b,weight):
 a=a.astype(np.int64);b=b.astype(np.int64)
 dx=np.zeros(a.shape,np.int64);dy=dx.copy()
 dx[:,1:]=np.abs((a[:,1:]-a[:,:-1])-(b[:,1:]-b[:,:-1]))
 dy[1:,:]=np.abs((a[1:,:]-a[:-1,:])-(b[1:,:]-b[:-1,:]))
 return np.abs(a-b)+weight*(dx+dy)

def shortest(c,horizontal):
 if horizontal:c=c.T
 h,w=c.shape;paths=[(int(c[0,x]),(x,)) for x in range(w)]
 for y in range(1,h):
  paths=[min(((v+int(c[y,x]),p+(x,)) for j,(v,p) in enumerate(paths) if abs(j-x)<=1),
             key=lambda t:(t[0],tuple(reversed(t[1])))) for x in range(w)]
 return min(paths,key=lambda t:(t[0],tuple(reversed(t[1]))))

def exhaustive(c,horizontal):
 if horizontal:c=c.T
 h,w=c.shape
 return min(((sum(int(c[y,x]) for y,x in enumerate(p)),p) for p in itertools.product(range(w),repeat=h)
             if all(abs(p[i]-p[i-1])<=1 for i in range(1,h))),key=lambda t:(t[0],tuple(reversed(t[1]))))

def mask_for(shape,path,horizontal,feather):
 result=np.zeros(shape,np.uint8);on=np.zeros(shape,np.uint8)
 for y in range(shape[0]):
  for x in range(shape[1]):
   d=(y-path[x]) if horizontal else (x-path[y]);on[y,x]=d==0
   result[y,x]=(255 if d<=0 else 0) if not feather else max(0,min(255,((feather-d)*255+feather)//(2*feather)))
 return result,on

def run(label,a,b,horizontal=False,weight=0,feather=0,replays=1,brute=False):
 h,w=a.shape;c=costs(a,b,weight);cost,path=shortest(c,horizontal)
 af,bf=a.astype(np.float64),b.astype(np.float64)
 dx=lambda z:cv2.filter2D(z,cv2.CV_64F,np.array([[-1.,1.]]),anchor=(1,0),borderType=cv2.BORDER_REPLICATE)
 dy=lambda z:cv2.filter2D(z,cv2.CV_64F,np.array([[-1.],[1.]]),anchor=(0,1),borderType=cv2.BORDER_REPLICATE)
 cv_cost=np.abs(af-bf)+weight*(np.abs(dx(af)-dx(bf))+np.abs(dy(af)-dy(bf)))
 assert np.array_equal(c,cv_cost)
 if brute:assert (cost,path)==exhaustive(c,horizontal)
 tc,tp=shortest(costs(a.T,b.T,weight),not horizontal);assert (cost,path)==(tc,tp)
 masks,on=mask_for(a.shape,path,horizontal,feather)
 init='\n'.join(f"p[{i}]=16'h{x:02x}{y:02x};e[{i}]=12'h{((i==w*h-1)<<11)|((i%w==w-1)<<10)|((i==0)<<9)|(int(z)<<8)|int(m):03x};" for i,(x,y,m,z) in enumerate(zip(a.flat,b.flat,masks.flat,on.flat)))
 packed=sum(x<<(i*6) for i,x in enumerate(path))
 tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,cfg_valid=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[5:0]cfg_width=WW,cfg_height=HH,cfg_feather=FF;reg cfg_horizontal=DD;reg[7:0]cfg_gradient_weight=GG;
 reg[7:0]s_a=0,s_b=0;
 wire cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_is_seam,done_valid,busy;
 wire[7:0]m_mask;wire[191:0]seam_coordinates;wire[5:0]seam_length;wire[31:0]total_cost;wire[3:0]error_code;
 seam_find dut(.*);
 reg[15:0]p[0:NN-1];reg[11:0]e[0:NN-1];reg[11:0]held;reg stalled=0;integer cycles=0,i,r,got=0;
 wire[11:0]token={m_last,m_eol,m_sof,m_is_seam,m_mask};
 localparam[191:0]PATH=192'hPP;localparam[31:0]COST=CC;
 always @(negedge clk)begin cycles=cycles+1;ce=cycles%13!=0&&cycles%13!=1;m_ready=cycles%7<4;if(cycles>3000000)$fatal(1,"timeout");end
 always @(posedge clk)if(rst_n)begin
  if(stalled&&(!m_valid||token!==held))$fatal(1,"unstable output");
  stalled=m_valid&&!(ce&&m_ready);held=token;
  if(ce&&m_valid&&m_ready)begin if(got>=NN||token!==e[got])$fatal(1,"pixel %d got=%h expected=%h",got,token,e[got]);got=got+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin
 INIT
 repeat(3)tick;rst_n=1;while(!cfg_ready)tick;cfg_valid=1;tick;cfg_valid=0;
 if(!cfg_done||cfg_error)$fatal(1,"cfg");
 for(r=0;r<RR;r=r+1)begin
  got=0;while(!start_ready)tick;start_valid=1;tick;start_valid=0;
  // Uncommitted configuration changes must not alter the frame.
  cfg_width=1;cfg_height=1;cfg_feather=0;cfg_horizontal=!DD;cfg_gradient_weight=255;
  for(i=0;i<NN;i=i+1)begin
   {s_a,s_b}=p[i];s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NN-1;
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  end
  while(!done_valid)tick;
  if(error_code||got!=NN||seam_coordinates!==PATH||total_cost!==COST||seam_length!=LEN)$fatal(1,"completion path=%h wanted=%h cost=%d expected=%d",seam_coordinates,PATH,total_cost,COST);
  abort=1;repeat(7)begin tick;if(!done_valid||error_code||seam_coordinates!==PATH||total_cost!==COST)$fatal(1,"held DONE late abort");end abort=0;
  while(!ce)tick;done_ready=1;tick;done_ready=0;tick;
 end
 $display("SEAM PASS");$finish;end endmodule'''
 for key,value in [('WW',w),('HH',h),('FF',feather),('DD',int(horizontal)),('GG',weight),('NN',w*h),('PP',f'{packed:x}'),('CC',cost),('LEN',len(path)),('RR',replays),('INIT',init)]:tb=tb.replace(key,str(value))
 with tempfile.TemporaryDirectory(prefix='seam_test_') as td:
  td=Path(td);(td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'seam_find.sv',td/'tb.sv'],td,td/'compile.log')
  assert 'SEAM PASS' in execute(['vvp',td/'sim'],td,td/'run.log',timeout=300)
 result=dict(label=label,width=w,height=h,horizontal=horizontal,gradient_weight=weight,feather=feather,
             path=list(path),cost=cost,replays=replays,exhaustive_checked=brute,opencv_cost_field_exact=True,status='PASS')
 print(result,flush=True);return result

def opencv_reference():
 # OpenCV solves overlap components with contour-selected terminals and a different
 # color edge objective; run the real algorithm, without claiming identical masks.
 a=np.zeros((24,24,3),np.float32);b=np.full_like(a,200);b[:,8]=0
 original=[cv2.UMat(np.full((24,24),255,np.uint8)) for _ in range(2)]
 result=cv2.detail_DpSeamFinder('COLOR').find([a,b],[(0,0),(8,2)],original)
 ma,mb=[p.get() for p in result]
 assert set(np.unique(ma))=={0,255} and set(np.unique(mb))=={0,255}
 # Both non-overlap portions retain their original ownership.
 assert np.all(ma[:2,:]==255) and np.all(mb[-2:,:]==255)
 return dict(software='actual cv2.detail_DpSeamFinder COLOR',offsets=[[0,0],[8,2]],
             retained_pixels=[int(np.count_nonzero(ma)),int(np.count_nonzero(mb))],
             equivalence='conceptual DP seam reference only; contour terminals and color-edge objective differ from the specified free-terminal pixel-cost DP3')

def main():
 rng=np.random.default_rng(4819);cases=[]
 for w,h,d,g,f,brute in [(1,1,0,0,0,True),(1,7,0,255,3,True),(7,1,1,7,32,True),
                          (4,4,0,3,1,True),(4,3,1,255,2,True),(17,9,0,0,4,False),(31,17,1,11,6,False),(32,32,0,255,32,False)]:
  a=rng.integers(0,256,(h,w),dtype=np.uint8);b=rng.integers(0,256,(h,w),dtype=np.uint8)
  cases.append(run('random',a,b,bool(d),g,f,brute=brute))
 a=np.full((7,9),80,np.uint8);b=a.copy();cases.append(run('flat_tie',a,b,feather=0))
 a=np.zeros((12,9),np.uint8);b=np.full_like(a,200);curve=[3,3,4,4,3,2,2,3,4,5,5,4]
 for y,x in enumerate(curve):b[y,x]=0
 cases.append(run('known_curved_vertical',a,b,feather=2,replays=2));assert cases[-1]['path']==curve
 cases.append(run('known_curved_horizontal',a.T,b.T,horizontal=True,feather=0));assert cases[-1]['path']==curve
 report=dict(status='PASS',cases=cases,opencv_reference=opencv_reference(),board=False,
             rtl_sha256=hashlib.sha256((HERE/'seam_find.sv').read_bytes()).hexdigest())
 (HERE/'evidence.json').write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__':main()
