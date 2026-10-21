from pathlib import Path
import sys,tempfile,json,random,hashlib
import numpy as np
import cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
rng=random.Random(162873)
stats={'transactions':0,'hypotheses':0,'valid_models':0,'degenerate_hypotheses':0,'range_rejected':0}
comparisons=[]
def next_rng(r):
 r=(r^(r<<13))&0xffffffff;r^=r>>17;return (r^(r<<5))&0xffffffff
def trunc(n,d):return (-1 if (n<0)^(d<0) else 1)*(abs(n)//abs(d))
def oracle(points,iterations,seed,threshold,frac):
 n=len(points);r=seed or 1;best=None
 for hyp in range(iterations):
  i0=(r&65535)%n;r=next_rng(r)
  i1=(i0+1+(r&65535)%(n-1))%n;r=next_rng(r)
  i2=(r&65535)%(n-2);r=next_rng(r)
  small,large=sorted((i0,i1))
  if i2>=small:i2+=1
  if i2>=large:i2+=1
  assert len({i0,i1,i2})==3
  x,y,u,v=points[i0];x1,y1,u1,v1=points[i1];x2,y2,u2,v2=points[i2]
  dx1=x1-x;dy1=y1-y;du1=u1-u;dv1=v1-v
  dx2=x2-x;dy2=y2-y;du2=u2-u;dv2=v2-v
  det=dx1*dy2-dx2*dy1
  if det==0 or du1*dv2-du2*dv1==0:stats['degenerate_hypotheses']+=1;continue
  nums=(du1*dy2-du2*dy1,dx1*du2-dx2*du1,dv1*dy2-dv2*dy1,dx1*dv2-dx2*dv1)
  a,b,c,d=[trunc(z<<frac,det) for z in nums]
  tx=(u<<frac)-a*x-b*y;ty=(v<<frac)-c*x-d*y
  model=(a,b,tx,c,d,ty)
  if not all(-(1<<39)<=z<(1<<39) for z in model):stats['range_rejected']+=1;continue
  residuals=[abs(a*px+b*py+tx-(pu<<frac))+abs(c*px+d*py+ty-(pv<<frac)) for px,py,pu,pv in points]
  inliers=[z for z in residuals if z<=threshold];count=len(inliers);score=sum(inliers)
  if count>=3 and (best is None or count>best[1] or (count==best[1] and score<best[2])):best=(model,count,score,hyp)
 if best is None:return ((0,)*6,0,0,0,3)
 return best[0],best[1],best[2],1,0
def generate():
 cases=[]
 for label,mat in [('translation',(1,0,5000,0,1,-4000)),('rotation90',(0,-1,2000,1,0,1000)),('scale_shear',(1.5,.25,-2000,-.5,1.25,3000))]:
  pts=[]
  for i in range(32):
   x=rng.randrange(-500,501)*4;y=rng.randrange(-500,501)*4
   u=int(mat[0]*x+mat[1]*y+mat[2]);v=int(mat[3]*x+mat[4]*y+mat[5])
   if i>=24:u=rng.randrange(-10000,10001);v=rng.randrange(-10000,10001)
   pts.append((x,y,u,v))
  cases.append((label,pts,48,0x15283647,2<<8))
 cases.append(('collinear',[(i*2,i*3,i*4-100,i*5+10) for i in range(12)],12,1,256))
 cases.append(('collapsed_target',[(i%4,i//4,100,200) for i in range(12)],12,5,256))
 cases.append(('minimum3',[(-32768,-32768,-20000,10000),(32767,-32768,20000,10000),(-32768,32767,-20000,-10000)],1,0,65535))
 pts=[(i%8*100-400,i//8*100-400,i%8*100+5000,i//8*100-6000) for i in range(64)]
 cases.append(('capacity64',pts,12,77,256))
 # Nondegenerate source determinant -1, extreme target changes: huge slopes/intercept.
 cases.append(('range_limit',[(-32768,-32768,-32768,32767),(32767,32766,32767,-32768),(32766,32765,-32768,-32768)],3,1,0))
 tie=[(0,0,0,0),(10,0,10,0),(0,10,0,10),(10,10,20,20)]
 cases.append(('earliest_tie_seed1',tie,20,1,0))
 cases.append(('earliest_tie_seed2',tie,20,2,0))
 for j in range(4):
  pts=[]
  for i in range(16):
   x=rng.randrange(-2000,2001);y=rng.randrange(-2000,2001)
   if j<2:u=x+y//3+500+rng.randrange(-2,3);v=y-x//5-700+rng.randrange(-2,3)
   else:u=rng.randrange(-30000,30001);v=rng.randrange(-30000,30001)
   pts.append((x,y,u,v))
  cases.append(('noisy' if j<2 else 'random',pts,16,j+3,8<<8 if j<2 else 0xffffffff))
 return cases
def run(capacity,frac,cases):
 expected=[];inputs=[];offsets=[]
 for label,pts,iters,seed,th in cases:
  result=oracle(pts,iters,seed,th,frac);expected.append(result);offsets.append(len(inputs))
  for i,p in enumerate(pts):inputs.append((*p,int(i==0),int(i==len(pts)-1),len(pts) if i==0 else 0,iters if i==0 else 0,seed if i==0 else ~seed&0xffffffff,th if i==0 else 0))
  stats['transactions']+=1;stats['hypotheses']+=iters;stats['valid_models']+=result[3]
  if frac==8 and label in ('translation','rotation90','scale_shear'):
   a=np.array(pts,dtype=float);cv,mask=cv2.estimateAffine2D(a[:,:2].copy(),a[:,2:].copy(),method=cv2.RANSAC,ransacReprojThreshold=2,maxIters=2000,confidence=.99,refineIters=0)
   independent=np.linalg.lstsq(np.column_stack((a[:24,0],a[:24,1],np.ones(24))),a[:24,2:],rcond=None)[0].T
   rtl=np.array(result[0],dtype=float).reshape(2,3)/2**frac
   assert result[1]>=24 and np.max(np.abs(rtl-independent))<1e-7
   assert cv is not None and np.max(np.abs(cv-independent))<1e-5
   comparisons.append({'case':label,'numpy_max_error':float(np.max(np.abs(rtl-independent))),'opencv_max_error':float(np.max(np.abs(cv-independent))),'rtl_inliers':result[1],'opencv_inliers':int(mask.sum())})
 with tempfile.TemporaryDirectory(prefix='affine_ransac_') as td:
  td=Path(td)
  def pack(s):
   x,y,u,v,first,last,count,iters,seed,th=s
   return (x&65535)|((y&65535)<<16)|((u&65535)<<32)|((v&65535)<<48)|(first<<64)|(last<<65)|(count<<66)|(iters<<73)|(seed<<89)|(th<<121)
  (td/'points.hex').write_text('\n'.join(f'{pack(s):x}' for s in inputs)+'\n')
  def packout(exp):
   model,count,score,valid,error=exp;value=0
   for i,z in enumerate(model):value|=(z&((1<<40)-1))<<(40*i)
   return value|(count<<240)|(score<<247)|(valid<<311)|(error<<312)
  (td/'expected.hex').write_text('\n'.join(f'{packout(e):x}' for e in expected)+'\n')
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,s_valid=0,s_first=0,s_last=0,m_ready=0;
 reg signed [15:0]s_x=0,s_y=0,s_u=0,s_v=0;
 reg [6:0]cfg_count=0;reg [15:0]cfg_iterations=0;reg [31:0]cfg_seed=0,cfg_threshold=0;
 wire s_ready,busy,done,m_valid,model_valid;wire [3:0]error_code;wire [6:0]best_count;wire [63:0]best_residual;
 wire signed [39:0]a00,a01,a02,a10,a11,a12;
 affine_ransac #(.CAPACITY({capacity}),.FRAC({frac}))dut(.*);
 reg [152:0]ins[0:{len(inputs)-1}];reg [315:0]expected[0:{len(cases)-1}];reg [315:0]held;
 integer f,i,k,tx,cycles,base,n,t,target;reg stalled;
 wire [315:0]actual={{error_code,model_valid,best_residual,best_count,a12,a11,a10,a02,a01,a00}};
 task reset;begin @(negedge clk);rst_n=0;ce=0;@(negedge clk);if(m_valid||busy||done||error_code)$fatal(1,"reset leak");rst_n=1;ce=1;s_valid=0;m_ready=0;end endtask
 task input_at(input integer pos);begin
 {{cfg_threshold,cfg_seed,cfg_iterations,cfg_count,s_last,s_first,s_v,s_u,s_y,s_x}}=ins[pos];end endtask
 initial begin
 $readmemh("points.hex",ins);$readmemh("expected.hex",expected);reset;base=0;
 // Two complete replays verify deterministic seeds and no stale score state.
 for(k=0;k<2;k=k+1)begin base=0;
 for(f=0;f<{len(cases)};f=f+1)begin
  tx=0;cycles=0;n=ins[base][72:66];stalled=0;
  while(!m_valid)begin
   @(negedge clk);ce=(cycles%7!=2);s_valid=(tx<n && cycles%4!=1);if(tx<n)input_at(base+tx);
   @(posedge clk);if(ce&&s_valid&&s_ready)tx=tx+1;#1;
   cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout");
  end
  if(actual!==expected[f])$fatal(1,"numeric case %0d got %h expected %h",f,actual,expected[f]);
  held=actual;
  repeat(4)begin @(negedge clk);ce=1;@(posedge clk);#1;if(!m_valid||actual!==held)$fatal(1,"stall");end
  @(negedge clk);ce=0;m_ready=1;@(posedge clk);#1;if(!m_valid||actual!==held)$fatal(1,"CE stalled");
  @(negedge clk);ce=1;@(posedge clk);#1;if(m_valid||!done||busy)$fatal(1,"completion");
  @(negedge clk);m_ready=0;s_valid=0;base=base+n;
 end end
 // Bad count/iteration/markers produce explicit held error records.
 for(i=0;i<4;i=i+1)begin
  @(negedge clk);s_valid=1;s_first=(i!=2);s_last=(i==3);cfg_count=(i==0)?2:3;cfg_iterations=(i==1)?0:1;
  @(posedge clk);#1;if(!m_valid||model_valid||error_code!=((i<2)?1:2))$fatal(1,"bad config/header");reset;
 end
 // Capacity + 1 is rejected, not truncated into memory addresses.
 @(negedge clk);s_valid=1;s_first=1;s_last=0;cfg_count={capacity+1};cfg_iterations=1;
 @(posedge clk);#1;if(!m_valid||error_code!=1)$fatal(1,"capacity");reset;
 // Mid-stream first/last consistency and missing terminal marker.
 for(k=0;k<3;k=k+1)begin
  for(i=0;i<3;i=i+1)begin
   @(negedge clk);s_valid=1;s_first=(i==0 || (k==0 && i==1));s_last=(k==1 && i==1);cfg_count=3;cfg_iterations=1;
   @(posedge clk);#1;
   if((k<2 && i==1)||(k==2 && i==2))begin
    if(!m_valid||model_valid||error_code!=2)$fatal(1,"mid-stream marker");i=3;
   end
  end
  reset;
 end
 // Reset with CE low during partial capture, multiplier, divider, scoring and held result.
 for(target=0;target<5;target=target+1)begin
  n=ins[0][72:66];
  for(i=0;i<((target==0)?1:n);i=i+1)begin @(negedge clk);input_at(i);s_valid=1;end
  @(negedge clk);s_valid=0;t=0;
  if(target!=0)begin
   while((target==1 && dut.state!=10)||(target==2 && dut.state!=12)||(target==3 && dut.state!=27)||(target==4 && !m_valid))begin
    @(negedge clk);t=t+1;if(t>1000000)$fatal(1,"reset reach");end
  end
  reset;
 end
 $display("AFFINE RANSAC PASS");$finish;
 end
 initial begin #1000000000;$fatal(1,"watchdog");end
 endmodule'''
  (td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'affine_ransac.sv',td/'tb.sv'],td,td/'compile.log')
  assert 'AFFINE RANSAC PASS' in execute(['vvp',td/'sim'],td,td/'sim.log',timeout=300)
 print('PASS',capacity,frac,len(cases))
def guards():
 with tempfile.TemporaryDirectory(prefix='affine_guards_') as td:
  td=Path(td)
  for cfg in ('.CAPACITY(31)','.CAPACITY(65)','.FRAC(17)'):
   (td/'tb.sv').write_text(f'module bad;affine_ransac #({cfg})dut();initial begin #10;$fatal(1,"guard missing");end endmodule')
   execute(['iverilog','-g2012','-s','bad','-o',td/'sim',HERE/'affine_ransac.sv',td/'tb.sv'],td,td/'compile.log')
   try:execute(['vvp',td/'sim'],td,td/'sim.log')
   except RuntimeError:assert 'invalid affine parameters' in (td/'sim.log').read_text()
   else:raise AssertionError('invalid accepted')
 stats['invalid_parameter_cases']=3
if __name__=='__main__':
 cases=generate()
 run(32,8,[c for c in cases if len(c[1])<=32]);run(64,8,[c for c in cases if c[0]=='capacity64']);run(32,16,[c for c in cases if c[0] in ('minimum3','range_limit')]);run(32,0,[c for c in cases if c[0] in ('translation','earliest_tie_seed1')])
 assert stats['range_rejected']>0
 guards()
 evidence={'result':'PASS',**stats,'rtl_complete_replays':2,'rtl_completed_transactions':2*stats['transactions'],'rtl_hypotheses':2*stats['hypotheses'],'comparisons':comparisons,'opencv_version':cv2.__version__,'board':False,'rtl_sha256':hashlib.sha256((HERE/'affine_ransac.sv').read_bytes()).hexdigest()}
 (HERE/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n');print(evidence)

