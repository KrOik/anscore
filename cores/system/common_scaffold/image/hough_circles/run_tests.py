import sys,os,json,tempfile,subprocess,time,hashlib
from pathlib import Path
import numpy as np
import skimage
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
from oracle import oracle,skimage_audit,offsets
def draw(shape,circles):
 a=np.zeros(shape,dtype=np.uint8)
 for x,y,r in circles:
  for dx,dy in offsets(r):
   if 0<=x+dx<shape[1] and 0<=y+dy<shape[0]:a[y+dy,x+dx]=1
 return a
def simulate(body,w,h,mr,mc=8):
 with tempfile.TemporaryDirectory(prefix='hough_circles_') as temporary:
  td=Path(temporary);(td/'tb.v').write_text(TB.replace('@W@',str(w)).replace('@H@',str(h)).replace('@MR@',str(mr)).replace('@MC@',str(mc)).replace('@BODY@',body))
  p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'hough_circles_frame.v'),str(td/'tb.v')],cwd=ROOT,capture_output=True,text=True)
  if p.returncode:raise RuntimeError(p.stderr)
  p=subprocess.run(['vvp',str(td/'sim')],cwd=ROOT,capture_output=True,text=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  assert 'CIRCLES PASS' in p.stdout,p.stdout
 return p.stdout
def frame_body(edges,cfg,bad=0):
 rmin,rmax,threshold,limit,cnms,rnms=cfg;h,w=edges.shape
 expected=[] if bad else oracle(edges,*cfg)
 body=[f'beginframe({rmin},{rmax},{threshold},{limit},{cnms},{rnms});']
 for y in range(h):
  for x in range(w):
   sf=int(x==y==0);el=int(x==w-1)
   if bad==1 and x==y==0:sf=0
   if bad==2 and x==w-1 and y==h-1:sf=1
   if bad==4 and x==w-1 and y==h-1:el=0
   if bad==8 and x==0 and y==h-1:el=1
   body.append(f'send({int(edges[y,x])},{sf},{el});')
 for j,(x,y,r,v) in enumerate(expected):body.append(f'check_circle({x},{y},{r},{v},{j});')
 body.append(f'finish_frame({len(expected)},{bad});')
 return '\n'.join(body),expected
def run():
 start=time.monotonic();rng=np.random.default_rng(172093);records=[];external=[]
 # Geometry ROM is validated against a separately maintained public implementation.
 words=[int(s,16) for s in (ROOT/'offsets.mem').read_text().split()];meta=[int(s,16) for s in (ROOT/'metadata.mem').read_text().split()]
 for r in range(1,32):
  start0=meta[r]&4095;count=meta[r]>>12
  decode=lambda v:v-64 if v&32 else v
  actual={(decode(words[i]&63),decode(words[i]>>6)) for i in range(start0,start0+count)}
  assert actual==set(offsets(r)) and len(actual)==count
 profiles=[(1,1,1),(7,5,4),(16,16,8),(32,32,31)]
 for w,h,mr in profiles:
  cases=[]
  if w==1:
   cases=[(np.zeros((h,w),np.uint8),(1,1,1,1,0,0)),(np.ones((h,w),np.uint8),(1,1,1,1,0,0))]
  elif w==7:
   cases=[(np.zeros((h,w),np.uint8),(1,4,1,8,0,0)),(np.ones((h,w),np.uint8),(1,4,5,8,1,1))]
   for j in range(8):cases.append(((rng.random((h,w))<(.1+j*.1)).astype(np.uint8),(1+j%2,4,1+j,1+j%8,j%3,j%4)))
  elif w==16:
   cases=[(draw((h,w),[(7,8,4)]),(2,6,20,4,3,2)),(draw((h,w),[(0,5,5)]),(4,6,10,4,3,1)),(draw((h,w),[(7,8,4),(7,8,6)]),(3,7,18,8,2,0)),(rng.integers(0,2,(h,w),dtype=np.uint8),(2,8,12,8,2,2))]
  else:
   cases=[(draw((h,w),[(8,8,4),(23,22,6)]),(3,7,23,8,4,2)),(draw((h,w),[(15,15,15)]),(15,15,84,4,2,0)),(draw((h,w),[(0,16,31)]),(31,31,18,4,3,0)),(np.zeros((h,w),np.uint8),(1,31,1,8,31,31))]
  body=[]
  known={(16,0):[(7,8,4,24)],(16,1):[(0,5,5,15)],(16,2):[(7,8,6,32),(7,8,4,24)],(32,0):[(23,22,6,32),(8,8,4,24)],(32,1):[(15,15,15,84)],(32,2):[(0,16,31,32)]}
  for case_index,(edges,cfg) in enumerate(cases):
   text,expected=frame_body(edges,cfg);body.append(text);records.append({'width':w,'height':h,'max_radius':mr,'config':list(cfg),'edge_pixels':int(edges.sum()),'circles':expected})
   if (w,case_index) in known:assert expected==known[w,case_index],(w,case_index,expected)
   if w in (7,16):external.append(skimage_audit(edges,cfg[0],cfg[1]))
  if w==7:
   for bad in (1,2,4,8,0):
    text,expected=frame_body(np.ones((h,w),np.uint8),(1,4,6,4,2,2),bad);body.append(text)
  print('running',w,h,len(body),'frames',flush=True);print(simulate('\n'.join(body),w,h,mr),flush=True)
 from test_protocol import run as protocol
 protocol()
 result={'status':'PASS','frames':len(records)+5,'profiles':records,'protocol':{'reset_phases':10,'healthy_recovery_frames':11,'invalid_configs':9,'invalid_static':8,'max_output_count':32,'full_accumulator_bins':140},'skimage':skimage.__version__,'external_audits':external,'seconds':round(time.monotonic()-start,3),'rtl_sha256':hashlib.sha256((ROOT/'hough_circles_frame.v').read_bytes()).hexdigest()}
 (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
TB='''module tb;reg clk=0;always #5 clk=~clk;reg rst=1,ce=1,start_valid=0,s_valid=0,s_sof=0,s_eol=0,s_edge=0,m_ready=0,done_ready=0;reg[5:0]cfg_min_radius=1,cfg_max_radius=1,cfg_max_circles=1,cfg_center_nms=0,cfg_radius_nms=0;reg[7:0]cfg_vote_threshold=1;wire start_ready,s_ready,m_valid,done_valid,done_error,busy;wire[5:0]m_x,m_y,m_radius,m_index,done_count;wire[7:0]m_votes,error_code;
 hough_circles_frame #(.WIDTH(@W@),.HEIGHT(@H@),.MAX_RADIUS(@MR@),.MAX_CIRCLES(@MC@)) dut(.*);
 integer waits;
 task beginframe;input[5:0]r0,r1;input[7:0]th;input[5:0]lim,cn,rn;begin
 @(negedge clk);cfg_min_radius=r0;cfg_max_radius=r1;cfg_vote_threshold=th;cfg_max_circles=lim;cfg_center_nms=cn;cfg_radius_nms=rn;start_valid=1;@(negedge clk);start_valid=0;
 cfg_min_radius=0;cfg_max_radius=63;cfg_vote_threshold=0;cfg_max_circles=0;cfg_center_nms=63;cfg_radius_nms=63;
 end endtask
 task send;input edgebit,sf,el;begin
 waits=0;while(!s_ready)begin @(negedge clk);waits=waits+1;ce=waits%11!=0;end ce=1;
 s_edge=edgebit;s_sof=sf;s_eol=el;s_valid=1;@(negedge clk);s_valid=0;end endtask
 task check_circle;input[5:0]x,y,r;input[7:0]votes;input[5:0]idx;reg[31:0]held;begin
 waits=0;while(!m_valid&&!done_valid)begin @(negedge clk);waits=waits+1;ce=waits%11!=0;end ce=1;
 if(!m_valid||m_x!==x||m_y!==y||m_radius!==r||m_votes!==votes||m_index!==idx)$fatal(1,"circle got=%d,%d,%d,%d idx%d expected=%d,%d,%d,%d idx%d",m_x,m_y,m_radius,m_votes,m_index,x,y,r,votes,idx);
 held={m_x,m_y,m_radius,m_votes,m_index};repeat(3)@(negedge clk);if(!m_valid||held!=={m_x,m_y,m_radius,m_votes,m_index})$fatal(1,"output hold");
 ce=0;m_ready=1;repeat(2)@(negedge clk);if(!m_valid||s_ready||start_ready)$fatal(1,"CE hold");ce=1;@(negedge clk);m_ready=0;end endtask
 task finish_frame;input[5:0]count;input[7:0]err;begin
 waits=0;while(!done_valid&&!m_valid)begin @(negedge clk);waits=waits+1;ce=waits%11!=0;end ce=1;
 if(!done_valid||m_valid||done_error!==(err!=0)||error_code!==err||done_count!==count)$fatal(1,"terminal err=%h expected=%h count=%d expected=%d",error_code,err,done_count,count);
 repeat(3)@(negedge clk);if(!done_valid||start_ready||s_ready)$fatal(1,"DONE hold");ce=0;done_ready=1;@(negedge clk);if(!done_valid)$fatal(1,"DONE CE");ce=1;@(negedge clk);done_ready=0;if(busy||done_valid)$fatal(1,"DONE ack");end endtask
 initial begin repeat(2)@(negedge clk);rst=0;@BODY@ $display("CIRCLES PASS");$finish;end
 initial begin #1000000000;$fatal(1,"timeout");end endmodule'''
if __name__=='__main__':run()
