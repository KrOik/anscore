import sys,math,json,tempfile,hashlib,re
from pathlib import Path
import numpy as np
from skimage.transform import hough_line
import cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute

def coefficients():
 return [(round(math.cos(math.radians(t))*16384),round(math.sin(math.radians(t))*16384)) for t in range(180)]

def accumulator(image,step=1):
 # Exhaustive bin-first search, not the RTL edge-first address sequence.
 yy,xx=np.indices(image.shape);out=[]
 for c,s in coefficients()[::step]:
  dot=xx*c+yy*s
  rho=np.sign(dot)*((np.abs(dot)+8192)//16384)
  out.append([int(np.count_nonzero(image&(rho==r))) for r in range(-45,46)])
 return np.array(out,dtype=np.int64)

def oracle(image,threshold,limit,tn,rn,step=1):
 a=accumulator(image,step);peaks=[]
 for _ in range(limit):
  ti,ri=np.unravel_index(a.argmax(),a.shape);score=int(a[ti,ri])
  if score<threshold:break
  theta=int(ti*step);rho=int(ri-45);peaks.append((theta,rho,score))
  for i in range(a.shape[0]):
   delta=abs(i*step-theta);wrap=delta>90;delta=min(delta,180-delta)
   if delta<=tn:
    for j in range(91):
     if abs(j-45+(rho if wrap else -rho))<=rn:a[i,j]=0
 return peaks

def run_case(image,step,threshold,limit,tn,rn,label):
 h,w=image.shape;expected=oracle(image,threshold,limit,tn,rn,step)
 init='\n'.join(f'p[{i}]=1\'b{int(v)};' for i,v in enumerate(image.flat))
 checks='\n'.join(f'{i}:if(m_theta!={t}||$signed(m_rho)!={r}||m_score!={s})$fatal(1,"peak {i}: %d %d %d",m_theta,$signed(m_rho),m_score);' for i,(t,r,s) in enumerate(expected))
 # Full pre-NMS accumulator checked on first SCAN_INIT, all bins.
 bins=accumulator(image,step).flat
 init+='\n'+'\n'.join(f'e[{i}]={int(v)};' for i,v in enumerate(bins))
 tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_edge=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[10:0]cfg_threshold=TH;reg[4:0]cfg_max_lines=LIM;reg[6:0]cfg_theta_nms=TN,cfg_rho_nms=RN;
 wire start_ready,s_ready,m_valid,done_valid,done_error,busy;wire[7:0]m_theta;wire signed[7:0]m_rho;wire[10:0]m_score;wire[4:0]m_index;wire[3:0]error_code;
 hough_lines_full #(.WIDTH(W),.HEIGHT(H),.THETA_STEP(STEP))dut(.*);
 reg p[0:W*H-1];integer e[0:(180/STEP)*91-1];integer i,n=0,cy=0;reg checked=0,holding=0;reg[31:0] held;reg[31:0]rng=32'h13579abc;
 wire[31:0]token={m_index,m_theta,m_rho,m_score};
 always @(posedge clk)begin
  cy=cy+1;if(cy>12000000)$fatal(1,"timeout %d",dut.state);
  if(rst_n&&ce&&dut.state==15&&!checked)begin for(integer j=0;j<(180/STEP)*91;j=j+1)if(dut.votes[j]!==e[j])$fatal(1,"bin %d got=%d exp=%d",j,dut.votes[j],e[j]);checked=1;end
  if(rst_n)begin if(holding&&(!m_valid||token!==held))$fatal(1,"hold");holding=m_valid&&!(ce&&m_ready);held=token;end else holding=0;
  if(rst_n&&ce&&m_valid&&m_ready)begin
   if(m_index!=n)$fatal(1,"index");case(n) CHECKS default:$fatal(1,"extra peak");endcase n=n+1;
  end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin INIT
 tick;rst_n=1;tick;start_valid=1;tick;start_valid=0;
 // Runtime config must be snapshotted.
 cfg_threshold=1;cfg_max_lines=16;cfg_theta_nms=90;cfg_rho_nms=90;
 for(i=0;i<W*H;i=i+1)begin
  s_edge=p[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==W*H-1;s_valid=1;
  if(i%5==0)begin ce=0;repeat(2)tick;if(s_ready)$fatal(1,"CE input ready");ce=1;#1;end
  while(!s_ready)tick;tick;s_valid=0;
 end
 while(!done_valid)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
 ce=1;m_ready=0;if(done_error||error_code||n!=COUNT||!checked)$fatal(1,"completion n=%d",n);
 repeat(4)begin tick;if(!done_valid||done_error)$fatal(1,"done hold");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE ack");ce=1;tick;done_ready=0;
 $display("PASS bins=%d peaks=%d",(180/STEP)*91,n);$finish;
 end endmodule'''
 for k,v in [('CHECKS',checks),('INIT',init),('COUNT',len(expected)),('STEP',step),('TH',threshold),('LIM',limit),('TN',tn),('RN',rn),('W',w),('H',h)]:tb=re.sub(r'\b'+k+r'\b',lambda _:str(v),tb)
 with tempfile.TemporaryDirectory(prefix='full_hough_') as temp:
  d=Path(temp);(d/'trig.mem').write_bytes((HERE/'trig.mem').read_bytes());(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',HERE/'hough_lines_full.sv',d/'tb.sv'],d,d/'compile.log')
  text=execute(['vvp',d/'sim'],d,d/'run.log',timeout=300);assert 'PASS' in text,text
 # Actual skimage full accumulator comparison: exclude only quantized-rho ties.
 theta=np.deg2rad(np.arange(0,180,step));sk,rtheta,rhos=hough_line(image,theta=theta)
 ours=accumulator(image,step);different=0;compared=0;ambiguities=0
 ey,ex=np.where(image)
 for ti,t in enumerate(theta):
  c,s=coefficients()[ti*step]
  fd=ex*np.cos(t)+ey*np.sin(t)
  error=(ex+ey)/(2*16384)+1e-10
  near=np.abs(np.abs(fd-np.floor(fd))-.5)<=error
  allowed=set()
  for z in fd[near]:allowed.update([math.floor(z),math.ceil(z)])
  ambiguities+=len(allowed)
  for ri,r in enumerate(rhos):
   if -45<=r<=45:
    mismatch=sk[ri,ti]!=ours[ti,int(r)+45]
    assert not mismatch or int(r) in allowed,(label,ti,r,'unexplained floating discrepancy')
    different+=int(mismatch);compared+=1
 # Q14 trig may alter nearest-bin ties. Record all discrepancies, not hidden tolerance.
 lines=cv2.HoughLines(image.astype(np.uint8)*255,1,np.pi/180,max(1,threshold-1))
 if label=='theta_wrap':
  assert expected==[(0,7,16)],expected
  assert lines is not None and any(abs(float(z[0])-7)<.1 and abs(float(z[1]))<.001 for z in lines[:,0,:])
 return dict(label=label,width=w,height=h,step=step,peaks=expected,all_integer_bins_exact=True,
  skimage_bins=compared,skimage_different_bins=different,skimage_ambiguity_certified=True,ambiguous_bins=ambiguities,
  opencv_lines=0 if lines is None else len(lines),opencv_first=None if lines is None else list(map(float,lines[0,0])))

def main():
 cases=[];rng=np.random.default_rng(426)
 for side,step in [(8,1),(16,1),(32,1),(7,5)]:
  yy,xx=np.indices((side,side));line=(yy==np.floor(xx*.5+1))
  cases.append((line,step,max(2,side//3),3,3,1,f'slope_half_{side}_{step}'))
  cases.append(((xx==0)|(yy==side-1)|(yy==side-1-xx),step,max(2,side//2),5,4,1,f'multiple_boundary_{side}_{step}'))
 cases += [(rng.random((9,11))<.22,3,3,4,5,2,'noise'),(np.zeros((1,1),bool),1,1,1,0,0,'empty'),(np.ones((2,2),bool),1,1,4,90,90,'dense_nms'),(np.eye(8,dtype=bool),1,4,16,0,0,'max16')]
 vertical=np.zeros((16,16),bool);vertical[:,7]=1
 assert accumulator(vertical)[179,38]>0
 cases += [(vertical,1,12,5,6,1,'theta_wrap'),(np.ones((32,1),bool),90,20,2,0,0,'thin_vertical'),(np.ones((1,32),bool),2,20,2,0,0,'thin_horizontal')]
 report=[]
 for args in cases:
  result=run_case(*args);report.append(result);print(result,flush=True)
 (HERE/'test_result.json').write_text(json.dumps(dict(status='PASS',cases=report,rtl_sha256=hashlib.sha256((HERE/'hough_lines_full.sv').read_bytes()).hexdigest(),board=False),indent=2)+'\n')
if __name__=='__main__':main()
