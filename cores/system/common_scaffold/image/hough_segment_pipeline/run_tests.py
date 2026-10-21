import sys,importlib.util,json,hashlib,tempfile,re
from pathlib import Path
import numpy as np
import cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
FULL=HERE.parent/'hough_lines_full';SEG=HERE.parent/'hough_segments'
SOURCES=[HERE/'hough_segment_pipeline.sv',FULL/'hough_lines_full.sv',SEG/'hough_segments.sv']
def load(path,name):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
polar=load(FULL/'run_tests.py','pipeline_polar_oracle')
segment=load(SEG/'run_tests.py','pipeline_segment_oracle')
def hashes():return {str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES+[HERE/'trig.mem']}
def oracle(image,cfg,step):
 threshold,max_candidates,tn,rn,tol,gap,length,support,limit=cfg
 peaks=polar.oracle(image,threshold,max_candidates,tn,rn,step);out=[]
 for i,(theta,rho,score) in enumerate(peaks):
  for j,token in enumerate(segment.oracle(image,theta,rho,tol,gap,length,support,limit)):out.append((i,j,theta,rho,*token))
 return peaks,out

TB=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_edge=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[10:0]cfg_threshold=TH;reg[4:0]cfg_max_candidates=MAXC;reg[6:0]cfg_theta_nms=TN,cfg_rho_nms=RN;
 reg[1:0]cfg_rho_tolerance=TOL;reg[5:0]cfg_max_gap=GAP,cfg_min_length=LEN,cfg_min_support=SUP,cfg_max_segments=LIM;
 wire start_ready,s_ready,m_valid,done_valid,done_error,busy;wire[7:0]error_code,m_theta;wire signed[7:0]m_rho;
 wire[5:0]m_x1,m_y1,m_x2,m_y2,m_support,m_segment_index;wire[11:0]m_length_squared;wire[4:0]m_candidate_index,detected_candidates;wire[9:0]emitted_segments;
 hough_segment_pipeline #(.WIDTH(W),.HEIGHT(H),.THETA_STEP(STEP))dut(.*);
 reg p[0:W*H-1];integer i,n=0,cy=0,replays=0,replay_pixels=0,full_pixels=0;
 reg[31:0]rng=32'hb91425ac;reg holding=0;reg[69:0]held;
 wire[69:0]token={m_candidate_index,m_segment_index,m_theta,m_rho,m_x1,m_y1,m_x2,m_y2,m_support,m_length_squared};
 always @(posedge clk)begin
  cy=cy+1;if(cy>14000000)$fatal(1,"watchdog %d",dut.state);
  if(ce&&((dut.seg_valid&&dut.segments.m_ready)!=(m_valid&&m_ready)))$fatal(1,"internal/external transfer mismatch");
  if(rst_n)begin if(holding&&(!m_valid||token!==held))$fatal(1,"output hold");holding=m_valid&&!(ce&&m_ready);held=token;end else holding=0;
  if(rst_n&&ce&&dut.polar.s_valid&&dut.polar.s_ready)full_pixels=full_pixels+1;
  if(rst_n&&ce&&dut.segments.s_valid&&dut.segments.s_ready)begin
   if(dut.segments.s_edge!==p[replay_pixels%(W*H)])$fatal(1,"actual replay edge mismatch");
   replay_pixels=replay_pixels+1;
  end
  if(rst_n&&ce&&dut.segments.start_valid&&dut.segments.start_ready)replays=replays+1;
  if(rst_n&&ce&&m_valid&&m_ready)begin case(n) CHECKS default:$fatal(1,"extra segment");endcase n=n+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin INIT
 tick;rst_n=1;tick;start_valid=1;tick;start_valid=0;
 cfg_threshold=1024;cfg_max_candidates=1;cfg_theta_nms=90;cfg_rho_nms=90;cfg_rho_tolerance=3;cfg_max_gap=31;cfg_min_length=44;cfg_min_support=32;cfg_max_segments=1;
 for(i=0;i<W*H;i=i+1)begin s_edge=p[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==W*H-1;s_valid=1;
 if(i%7==0)begin ce=0;repeat(2)tick;if(s_ready)$fatal(1,"capture CE");ce=1;#1;end
 while(!s_ready)tick;tick;s_valid=0;end
 while(!done_valid)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
 ce=1;m_ready=0;
 if(done_error||error_code||n!=COUNT||emitted_segments!=COUNT||detected_candidates!=CAND||replays!=CAND||replay_pixels!=CAND*W*H||full_pixels!=W*H)$fatal(1,"completion n=%d cand=%d replays=%d rp=%d",n,detected_candidates,replays,replay_pixels);
 repeat(4)begin tick;if(!done_valid||done_error||emitted_segments!=COUNT)$fatal(1,"held DONE");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE DONE ACK");ce=1;tick;done_ready=0;
 $display("PASS candidates=%d segments=%d pixels=%d cycles=%d",detected_candidates,n,replay_pixels,cy);$finish;end endmodule'''

def run_case(image,cfg,step,label):
 peaks,expected=oracle(image,cfg,step);h,w=image.shape
 checks=[]
 for i,(ci,si,t,r,x1,y1,x2,y2,support,length) in enumerate(expected):
  assert image[y1,x1] and image[y2,x2]
  checks.append(f'{i}:if(m_candidate_index!={ci}||m_segment_index!={si}||m_theta!={t}||$signed(m_rho)!={r}||m_x1!={x1}||m_y1!={y1}||m_x2!={x2}||m_y2!={y2}||m_support!={support}||m_length_squared!={length})$fatal(1,"segment {i}");')
 init='\n'.join(f'p[{i}]=1\'b{int(v)};' for i,v in enumerate(image.flat));tb=TB
 for k,v in zip(['TH','MAXC','TN','RN','TOL','GAP','LEN','SUP','LIM'],cfg):tb=re.sub(r'\b'+k+r'\b',str(v),tb)
 for k,v in [('CHECKS','\n'.join(checks)),('INIT',init),('W',w),('H',h),('STEP',step),('COUNT',len(expected)),('CAND',len(peaks))]:tb=re.sub(r'\b'+k+r'\b',lambda _:str(v),tb)
 with tempfile.TemporaryDirectory(prefix='hough_pipeline_') as tmp:
  d=Path(tmp);(d/'trig.mem').write_bytes((HERE/'trig.mem').read_bytes());(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log')
  result=execute(['vvp',d/'sim'],d,d/'run.log',timeout=300);assert 'PASS' in result,result;print(label,result.strip(),flush=True)
 cv2.setRNGSeed(118)
 raw=cv2.HoughLinesP(image.astype(np.uint8)*255,1,np.pi/180,max(2,min(8,cfg[7])),minLineLength=cfg[6],maxLineGap=cfg[5])
 cv=[] if raw is None else np.asarray(raw).reshape(-1,4).astype(int).tolist()
 for a,b,c,d in cv:assert image[b,a] and image[d,c]
 if label=='joined_line':
  normalize=lambda z:tuple(sorted([tuple(z[:2]),tuple(z[2:])]))
  assert {normalize(z) for z in cv}=={((1,3),(30,3))}
 return dict(label=label,width=w,height=h,step=step,config=cfg,candidates=peaks,segments=expected,opencv=cv,simulation=result.strip())

def main():
 frozen=hashes();cases=[]
 im=np.zeros((8,32),bool);im[3,1:11]=1;im[3,15:31]=1
 cases.append((im,(20,1,4,1,0,4,5,3,32),1,'joined_line'))
 yy,xx=np.indices((16,16));cases.append(((xx==4)|(yy==10),(12,4,4,1,0,0,5,4,32),1,'multiple_candidates'))
 cases.append((np.eye(8,dtype=bool),(4,16,0,0,0,0,1,2,32),1,'max16_candidates'))
 yy,xx=np.indices((16,16));cases.append((yy==np.floor(xx*.5+1),(7,3,3,1,0,1,3,3,32),1,'non4_angle'))
 cases.append((np.zeros((1,1),bool),(1,16,0,0,0,0,1,2,32),1,'no_peaks'))
 im=np.zeros((3,32),bool);im[1,::3]=1;im[1,1::3]=1
 cases.append((im,(20,1,3,1,0,0,1,2,32),1,'eleven_segments'))
 cases.append((np.ones((32,32),bool),(1024,16,0,0,0,0,1,2,32),1,'large_no_peak'))
 rng=np.random.default_rng(133);cases.append((rng.random((9,11))<.28,(4,5,5,2,1,1,2,2,2),5,'noise_step5'))
 results=[run_case(*args) for args in cases]
 assert frozen==hashes(),'source mutation during hierarchy regression'
 (HERE/'test_result.json').write_text(json.dumps(dict(status='PASS',cases=results,sources=frozen,board=False),indent=2)+'\n')
if __name__=='__main__':main()
