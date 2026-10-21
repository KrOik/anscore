"""Fraction normal-equation oracle plus actual OpenCV perspective estimation."""
from fractions import Fraction as F
import hashlib,json,random,sys,tempfile
from pathlib import Path
import cv2
import numpy as np
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
Q=1<<24

def solve(points,mask):
 rows=[]
 for i,(x,y,u,v) in enumerate(points):
  if mask>>i&1:
   rows += [[F(x),F(y),F(1),F(0),F(0),F(0),F(-u*x),F(-u*y),F(u)],
            [F(0),F(0),F(0),F(x),F(y),F(1),F(-v*x),F(-v*y),F(v)]]
 m=[[sum(r[i]*r[j] for r in rows) for j in range(9)] for i in range(8)]
 for k in range(8):
  p=max(range(k,8),key=lambda i:abs(m[i][k]));assert m[p][k]
  m[k],m[p]=m[p],m[k];d=m[k][k];m[k]=[a/d for a in m[k]]
  for i in range(8):
   if i!=k:
    d=m[i][k];m[i]=[a-d*b for a,b in zip(m[i],m[k])]
 return [m[i][8] for i in range(8)]+[F(1)]

def project(h,x,y):
 d=h[6]*x+h[7]*y+h[8]
 return ((h[0]*x+h[1]*y+h[2])/d,(h[3]*x+h[4]*y+h[5])/d)

def run(label,points,budget=12,threshold=2,seed=9123,expect_error=None,replays=1):
 init='\n'.join(f'pts[{i}]=64\'h'+''.join(f'{v&65535:04x}' for v in p)+';' for i,p in enumerate(points))
 tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,s_valid=0,s_first=0,s_last=0,m_ready=0;
 reg signed [15:0] s_x,s_y,s_u,s_v;
 wire s_ready,busy,done,model_valid,m_valid;wire[3:0]error_code;
 wire signed[63:0] h00,h01,h02,h10,h11,h12,h20,h21,h22;
 wire[63:0]inlier_mask,refit_mask,best_residual;
 wire[6:0]best_count;wire[15:0]hypotheses,degenerate_count,overflow_count;
 localparam [6:0] COUNT=NN;localparam[15:0]BUDGET=BB;localparam[31:0]SEED=SS,THRESHOLD=TT;
 homography_ransac dut(.clk(clk),.rst_n(rst_n),.ce(ce),.s_x(s_x),.s_y(s_y),.s_u(s_u),.s_v(s_v),
 .s_valid(s_valid),.s_first(s_first),.s_last(s_last),.s_ready(s_ready),.cfg_count(COUNT),
 .cfg_iterations(BUDGET),.cfg_seed(SEED),.cfg_threshold(THRESHOLD),
 .h00(h00),.h01(h01),.h02(h02),.h10(h10),.h11(h11),.h12(h12),.h20(h20),.h21(h21),.h22(h22),
 .inlier_mask(inlier_mask),.refit_mask(refit_mask),.best_count(best_count),.best_residual(best_residual),
 .hypotheses(hypotheses),.degenerate_count(degenerate_count),.overflow_count(overflow_count),
 .model_valid(model_valid),.m_valid(m_valid),.m_ready(m_ready),.busy(busy),.done(done),.error_code(error_code));
 reg[63:0]pts[0:NN-1];integer i,r,cycles=0;reg accepted;
 reg[1023:0]saved;
 always @(negedge clk)begin cycles=cycles+1;ce=(cycles%11!=0&&cycles%11!=1);if(cycles>15000000)$fatal(1,"timeout state=%d",dut.state);end
 initial begin
 INIT
 repeat(3)@(negedge clk);rst_n=1;
 for(r=0;r<RR;r=r+1)begin
 for(i=0;i<NN;i=i+1)begin
 @(negedge clk);{s_x,s_y,s_u,s_v}=pts[i];s_first=i==0;s_last=i==NN-1;s_valid=1;accepted=0;
 while(!accepted)begin @(posedge clk);accepted=ce&&s_ready;@(negedge clk);end
 s_valid=0;
 end
 wait(m_valid);@(negedge clk);
 $display("RESULT %d %d %d %h %h %d %d %d %d",error_code,model_valid,best_count,inlier_mask,refit_mask,best_residual,hypotheses,degenerate_count,overflow_count);
 $display("H %d %d %d %d %d %d %d %d %d",h00,h01,h02,h10,h11,h12,h20,h21,h22);
 saved={h00,h01,h02,h10,h11,h12,h20,h21,h22,inlier_mask,refit_mask,best_count,best_residual,hypotheses,degenerate_count,overflow_count,model_valid,error_code};
 repeat(17)begin @(negedge clk);if(!m_valid||!done||{h00,h01,h02,h10,h11,h12,h20,h21,h22,inlier_mask,refit_mask,best_count,best_residual,hypotheses,degenerate_count,overflow_count,model_valid,error_code}!==saved)$fatal(1,"held DONE");end
 m_ready=1;accepted=0;while(!accepted)begin @(posedge clk);accepted=ce;@(negedge clk);end m_ready=0;
 end
 $finish;end
 endmodule'''
 for key,val in [('NN',len(points)),('BB',budget),('SS',seed),('TT',round(threshold*65536)),('RR',replays),('INIT',init)]:tb=tb.replace(key,str(val))
 with tempfile.TemporaryDirectory(prefix='homography_test_') as td:
  td=Path(td);(td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'homography_ransac.sv',td/'tb.sv'],td,td/'compile.log')
  log=execute(['vvp',td/'sim'],td,td/'run.log',timeout=300)
 rows=[l.split()[1:] for l in log.splitlines() if l.startswith('RESULT ')]
 models=[[int(v)/Q for v in l.split()[1:]] for l in log.splitlines() if l.startswith('H ')]
 assert len(rows)==replays,(label,log)
 reports=[]
 for values,h in zip(rows,models):
  err,valid,count=int(values[0]),int(values[1]),int(values[2]);mask=int(values[3],16);fit=int(values[4],16)
  print(label,err,valid,count,'mask',hex(mask),'stats',values[6:],flush=True)
  if expect_error is not None:
   assert err==expect_error and not valid,(label,values);reports.append(dict(error=err));continue
  assert err==0 and valid and count>=4,(label,values)
  assert count==mask.bit_count()
  exact=solve(points,fit)
  errors=[]
  for i,(x,y,u,v) in enumerate(points):
   a=project(h,x,y);b=project(exact,x,y)
   errors.append(max(abs(float(a[0]-b[0])),abs(float(a[1]-b[1]))))
  assert max(errors)<.08,(label,max(errors),h,list(map(float,exact)))
  src=np.array([[x,y] for x,y,u,v in points],np.float64);dst=np.array([[u,v] for x,y,u,v in points],np.float64)
  cvh,cvm=cv2.findHomography(src,dst,cv2.RANSAC,threshold,maxIters=2000,confidence=.999)
  assert cvh is not None
  cvdiff=[]
  for i,(x,y,u,v) in enumerate(points):
   if mask>>i&1 and cvm[i,0]:
    a=project(h,x,y);b=project(cvh.reshape(-1),x,y)
    cvdiff.append(max(abs(float(aa-bb)) for aa,bb in zip(a,b)))
  assert cvdiff and max(cvdiff)<1 and count==int(cvm.sum()),(label,max(cvdiff),count,int(cvm.sum()))
  assert abs(h[6])+abs(h[7])>1e-5, 'fixture must remain truly perspective'
  inlier_error=[sum(abs(float(a)-b) for a,b in zip(project(h,x,y),(u,v))) for i,(x,y,u,v) in enumerate(points) if mask>>i&1]
  assert max(inlier_error)<=threshold+.03
  reports.append(dict(error=err,inliers=count,fit_inliers=fit.bit_count(),fraction_prediction_max_error=max(errors),
                      opencv_inliers=int(cvm.sum()),opencv_prediction_max_difference=max(cvdiff),opencv_h=cvh.tolist(),rtl_h=h,
                      hypotheses=int(values[6]),degenerate=int(values[7]),overflow=int(values[8])))
 if replays>1:assert rows[0]==rows[1] and models[0]==models[1]
 return dict(label=label,points=len(points),reports=reports,status='PASS')

def main():
 cases=[]
 corners=[(0,0,4,-3),(64,0,62,-5),(0,64,10,58),(64,64,68,52)]
 cases.append(run('true_perspective_four',corners,budget=1,threshold=.2,replays=2))
 rng=random.Random(412)
 h=[1.05,.08,4,-.03,.95,-3,.0018,-.0011,1]
 pts=[]
 for i in range(28):
  x,y=rng.randrange(-65,66),rng.randrange(-65,66);u,v=project(h,x,y)
  pts.append((x,y,round(u),round(v)) if i<24 else (x,y,rng.randrange(-90,91),rng.randrange(-90,91)))
 cases.append(run('random_perspective_outliers',pts,budget=16,threshold=2,replays=2))
 exact=[]
 for x in (-32,0,64):
  for y in (-32,-16,0,16,32):exact.append((x,y,64*x//(64+x),64*y//(64+x)))
 cases.append(run('integer_true_perspective',exact,budget=16,threshold=.1))
 pts=[];h=[.7,-.08,8,.07,.65,-5,.0009,-.0007,1]
 for i in range(64):
  x,y=rng.randrange(-100,101),rng.randrange(-100,101);u,v=project(h,x,y)
  pts.append((x,y,round(u),round(v)) if i<50 else (x,y,rng.randrange(-100,101),rng.randrange(-100,101)))
 cases.append(run('capacity64_perspective_outliers',pts,budget=16,threshold=2,seed=51987))
 cases.append(run('collinear',[(i*5,i*3,i*2,i*4) for i in range(8)],budget=3,expect_error=3))
 cases.append(run('destination_collinear',[(0,0,0,0),(64,0,10,10),(0,64,20,20),(64,64,30,30)],budget=2,expect_error=3))
 cases.append(run('coordinate_range_rejection',[(128,0,0,0)],budget=1,expect_error=2))
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',cases=cases,board=False,rtl_sha256=hashlib.sha256((HERE/'homography_ransac.sv').read_bytes()).hexdigest()),indent=2)+'\n')

if __name__=='__main__':main()
