import math,json,sys,tempfile,hashlib,re
from pathlib import Path
import numpy as np
import cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute

def oracle(image,theta,rho,tolerance,max_gap,min_length,min_support,limit):
 # Gather real edge coordinates, filter exact bin, independently sort records.
 c=round(math.cos(math.radians(theta))*16384);s=round(math.sin(math.radians(theta))*16384)
 major_x=abs(s)>=abs(c);points=[]
 for y,x in zip(*np.where(image)):
  x,y=int(x),int(y);dot=x*c+y*s
  r=(1 if dot>=0 else -1)*((abs(dot)+8192)//16384)
  if abs(r-rho)<=tolerance:points.append((x if major_x else y,abs(dot-rho*16384),y if major_x else x,x,y))
 points.sort();chosen={}
 for p in points:
  if p[0] not in chosen:chosen[p[0]]=p[3:]
 groups=[]
 for k,p in chosen.items():
  if not groups or k-groups[-1][-1][0]>max_gap+1:groups.append([])
  groups[-1].append((k,p))
 out=[]
 for group in groups:
  a,b=group[0][1],group[-1][1];length=(a[0]-b[0])**2+(a[1]-b[1])**2
  if len(group)>=min_support and length>=min_length**2:out.append((*a,*b,len(group),length))
 return out[:limit]

def run_case(image,cfg,label,cv_expected=None):
 h,w=image.shape;expected=oracle(image,*cfg)
 for x1,y1,x2,y2,_,_ in expected:assert image[y1,x1] and image[y2,x2]
 init='\n'.join(f'p[{i}]=1\'b{int(v)};' for i,v in enumerate(image.flat))
 checks='\n'.join(f'{i}:if(m_x1!={x1}||m_y1!={y1}||m_x2!={x2}||m_y2!={y2}||m_support!={n}||m_length_squared!={l})$fatal(1,"segment {i} %d %d %d %d %d %d",m_x1,m_y1,m_x2,m_y2,m_support,m_length_squared);' for i,(x1,y1,x2,y2,n,l) in enumerate(expected))
 tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_edge=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[7:0]cfg_theta=THETA;reg signed[7:0]cfg_rho=RHO;reg[1:0]cfg_rho_tolerance=TOL;
 reg[5:0]cfg_max_gap=GAP,cfg_min_length=LEN,cfg_min_support=SUP,cfg_max_segments=LIM;
 wire start_ready,s_ready,m_valid,done_valid,done_error,busy;wire[3:0]error_code;
 wire[5:0]m_x1,m_y1,m_x2,m_y2,m_support,m_index;wire[11:0]m_length_squared;
 hough_segments #(.WIDTH(W),.HEIGHT(H))dut(.*);
 reg p[0:W*H-1];integer i,n=0,cy=0;reg[31:0]rng=32'h4321abcd;reg holding=0;reg[47:0]held;wire[47:0]token={m_index,m_x1,m_y1,m_x2,m_y2,m_support,m_length_squared};
 always @(posedge clk)begin
  cy=cy+1;if(cy>500000)$fatal(1,"timeout %d",dut.state);
  if(rst_n)begin if(holding&&(!m_valid||token!==held))$fatal(1,"output hold");holding=m_valid&&!(ce&&m_ready);held=token;end else holding=0;
  if(rst_n&&ce&&m_valid&&m_ready)begin if(m_index!=n)$fatal(1,"index");case(n) CHECKS default:$fatal(1,"extra segment");endcase n=n+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin INIT
 tick;rst_n=1;tick;start_valid=1;tick;start_valid=0;
 cfg_theta=250;cfg_rho=100;cfg_rho_tolerance=3;cfg_max_gap=31;cfg_min_length=44;cfg_min_support=32;cfg_max_segments=32;
 while(!s_ready)tick;
 for(i=0;i<W*H;i=i+1)begin
  s_edge=p[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==W*H-1;s_valid=1;
  if(i%7==0)begin ce=0;repeat(2)tick;if(s_ready)$fatal(1,"input CE");ce=1;#1;end
  while(!s_ready)tick;tick;s_valid=0;
 end
 while(!done_valid)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
 ce=1;m_ready=0;if(done_error||error_code||n!=COUNT)$fatal(1,"completion %d",n);
 repeat(3)begin tick;if(!done_valid||done_error)$fatal(1,"done hold");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE ack");ce=1;tick;done_ready=0;
 $display("PASS segments=%d",n);$finish;end endmodule'''
 for k,v in zip(['THETA','RHO','TOL','GAP','LEN','SUP','LIM'],cfg):tb=re.sub(r'\b'+k+r'\b',str(v),tb)
 for k,v in [('CHECKS',checks),('INIT',init),('W',w),('H',h),('COUNT',len(expected))]:tb=re.sub(r'\b'+k+r'\b',lambda _:str(v),tb)
 with tempfile.TemporaryDirectory(prefix='hough_segments_') as tmp:
  d=Path(tmp);(d/'trig.mem').write_bytes((HERE/'trig.mem').read_bytes());(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',HERE/'hough_segments.sv',d/'tb.sv'],d,d/'compile.log')
  result=execute(['vvp',d/'sim'],d,d/'run.log');assert 'PASS' in result,result
 cv2.setRNGSeed(552)
 lines=cv2.HoughLinesP(image.astype(np.uint8)*255,1,np.pi/180,max(2,min(8,cfg[5])),minLineLength=cfg[4],maxLineGap=cfg[3])
 cv_segments=[] if lines is None else [list(map(int,z)) for z in np.asarray(lines).reshape(-1,4)]
 for x1,y1,x2,y2 in cv_segments:assert image[y1,x1] and image[y2,x2]
 if cv_expected is not None:
  normalize=lambda z:tuple(sorted([tuple(z[:2]),tuple(z[2:4])]))
  assert {normalize(z) for z in cv_expected}=={normalize(z[:4]) for z in expected},(label,expected)
  # PPHT may stop at interior support points. Require every known segment to
  # be represented by an actual returned subsegment, with real endpoints.
  for a,b,c,d in cv_expected:
   assert any(min(a,c)<=u<=max(a,c) and min(a,c)<=q<=max(a,c) and min(b,d)<=v<=max(b,d) and min(b,d)<=r<=max(b,d) for u,v,q,r in cv_segments),(label,cv_segments)
 return dict(label=label,width=w,height=h,config=cfg,segments=expected,opencv_segments=cv_segments,opencv_known_support_compared=cv_expected is not None,
  opencv_exact=None if cv_expected is None else {normalize(z) for z in cv_expected}=={normalize(z) for z in cv_segments})

def main():
 source_hash=hashlib.sha256((HERE/'hough_segments.sv').read_bytes()).hexdigest()
 cases=[];rng=np.random.default_rng(911)
 horizontal=np.zeros((16,32),bool);horizontal[5,1:11]=1;horizontal[5,15:31]=1
 cases.append((horizontal,(90,5,0,0,4,3,32),'separate_horizontal',[[1,5,10,5],[15,5,30,5]]))
 cases.append((horizontal,(90,5,0,4,4,3,32),'join_horizontal',[[1,5,30,5]]))
 cases.append((horizontal,(90,5,0,3,4,3,32),'gap_boundary',None))
 vertical=horizontal.T.copy();cases.append((vertical,(0,5,0,0,4,3,32),'vertical',[[5,1,5,10],[5,15,5,30]]))
 yy,xx=np.indices((32,32))
 for theta,rho,name,im in [(135,0,'diagonal',xx==yy),(45,22,'antidiagonal',xx+yy==31),(116,1,'slope_half',yy==np.floor(xx*.5+1)),(179,-7,'negative_rho',xx==7)]:
  cases.append((im,(theta,rho,0,1,5,3,32),name,None))
 cases.extend([(rng.random((19,23))<.35,(153,-4,2,2,3,2,5),'noise',None),(np.ones((7,9),bool),(90,3,3,0,2,2,32),'closest_support_tie',None),(np.zeros((1,1),bool),(0,0,0,0,1,2,1),'empty',[]),(np.ones((1,32),bool),(90,0,0,31,31,32,1),'max_support_length',[[0,0,31,0]])])
 isolated=np.zeros((3,32),bool);isolated[1,::3]=1;isolated[1,1::3]=1
 cases.append((isolated,(90,1,0,0,1,2,32),'many_segments',None))
 cases.append((isolated,(90,1,0,0,1,2,1),'limit_one',None))
 cases.append((np.ones((32,32),bool),(135,0,0,0,44,32,32),'minlength44_reject',None))
 tie=np.zeros((7,9),bool);tie[2,:]=1;tie[4,:]=1
 assert oracle(tie,90,3,1,0,2,2,32)==[(0,2,8,2,9,64)]
 cases.append((tie,(90,3,1,0,2,2,32),'equal_residual_tie',None))
 for i,theta in enumerate(range(0,180,17)):
  im=rng.random((8,9))<.48
  c=round(math.cos(math.radians(theta))*16384);s=round(math.sin(math.radians(theta))*16384)
  dot=4*c+3*s;rho=(1 if dot>=0 else -1)*((abs(dot)+8192)//16384)
  cases.append((im,(theta,rho,i%4,i%4,2,2,4),f'random_angle_{theta}',None))
 result=[]
 for args in cases:
  row=run_case(*args);result.append(row);print(row,flush=True)
 assert source_hash==hashlib.sha256((HERE/'hough_segments.sv').read_bytes()).hexdigest(),'source changed during regression'
 (HERE/'test_result.json').write_text(json.dumps(dict(status='PASS',cases=result,rtl_sha256=source_hash,board=False),indent=2)+'\n')
if __name__=='__main__':main()
