"""Integer cumulative oracle, actual OpenCV integral2, every SAT cell and rectangle."""
from pathlib import Path
import hashlib,json,random,sys,tempfile
import cv2
import numpy as np
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'integral_image.sv'

def cumulative(a):
 h=len(a);w=len(a[0]);s=[[0]*(w+1)for _ in range(h+1)];sq=[[0]*(w+1)for _ in range(h+1)]
 for y in range(h):
  rs=rq=0
  for x in range(w):
   v=int(a[y][x]);rs+=v;rq+=v*v;s[y+1][x+1]=s[y][x+1]+rs;sq[y+1][x+1]=sq[y][x+1]+rq
 return s,sq

def rectangle(a,r):
 x0,y0,x1,y1=r;h=len(a);w=len(a[0])
 if x0>x1 or y0>y1 or x1>w or y1>h:return 0,0,0,1
 vals=[int(a[y][x])for y in range(y0,y1)for x in range(x0,x1)]
 return sum(vals),sum(v*v for v in vals),len(vals),0

TB=r'''module tb;
 localparam W=WW,H=HH,B=BB,N=W*H,F=FF,Q=QQ;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0;
 reg[B-1:0]s_data=0;reg done_ready=0,query_valid=0,result_ready=0;
 reg[15:0]query_x0=0,query_y0=0,query_x1=0,query_y1=0;
 wire start_ready,s_ready,done_valid,done_error,frame_valid,query_ready,result_valid,result_error;
 wire[3:0]error_code,result_error_code;wire[31:0]accepted_pixels,result_sum,result_count;wire[39:0]result_sqsum;
 integral_image #(.WIDTH(W),.HEIGHT(H),.BITS(B))dut(.*);
 reg[B-1:0]pixels[0:F*N-1];reg[63:0]rects[0:F*Q-1];reg[108:0]answers[0:F*Q-1];
 integer f,k,q,seen=0,cycles=0;reg got_start,got_input,got_done,got_query,got_result;
 reg[31:0]rng=32'h16273aae;reg held=0;reg[108:0]held_token;
 wire[108:0]token={result_error_code,result_error,result_count,result_sqsum,result_sum};
 always @(posedge clk)if(rst_n)begin
  cycles=cycles+1;if(cycles>5000000)$fatal(1,"timeout state %d",dut.state);
  if(held&&(!result_valid||token!==held_token))$fatal(1,"unstable response");
  held=result_valid&&!(ce&&result_ready);held_token=token;
  if(ce&&result_valid&&result_ready)begin
   if(seen>=F*Q||token!==answers[seen])$fatal(1,"query %d got %h expected %h",seen,token,answers[seen]);
   seen=seen+1;
  end
 end
 task tick;begin
  @(negedge clk);rng=(rng>>1)^(rng[0]?32'hd0000001:0);ce=rng[2:0]!=0;result_ready=rng[5:3]!=0;
  @(posedge clk);got_start=ce&&start_valid&&start_ready;got_input=ce&&s_valid&&s_ready;
  got_done=ce&&done_valid&&done_ready;got_query=ce&&query_valid&&query_ready;got_result=ce&&result_valid&&result_ready;#1;
 end endtask
 initial begin
  $readmemh("PIX",pixels);$readmemh("RECT",rects);$readmemh("ANS",answers);
  repeat(3)@(posedge clk);#1;rst_n=1;
  repeat(3)begin tick();if(query_ready||frame_valid)$fatal(1,"unconfigured query");end
  for(f=0;f<F;f=f+1)begin
   start_valid=1;do tick();while(!got_start);start_valid=0;
   if(frame_valid||accepted_pixels||query_ready)$fatal(1,"new frame isolation");
   for(k=0;k<N;k=k+1)begin
    s_data=pixels[f*N+k];s_valid=1;s_sof=k==0;s_eol=k%W==W-1;s_last=k==N-1;
    do tick();while(!got_input);s_valid=0;
    if(accepted_pixels!=k+1)$fatal(1,"accepted count");
    if(query_ready)$fatal(1,"query mid-frame");
   end
   while(!done_valid)tick();
   if(done_error||error_code||!frame_valid||accepted_pixels!=N)$fatal(1,"frame done");
   repeat(4)begin tick();if(!done_valid||query_ready||start_ready)$fatal(1,"DONE hold");end
   done_ready=1;do tick();while(!got_done);done_ready=0;
   for(q=0;q<Q;q=q+1)begin
    {query_y1,query_x1,query_y0,query_x0}=rects[f*Q+q];query_valid=1;
    do tick();while(!got_query);query_valid=0;
    query_x0=65535;query_y0=65535;query_x1=65535;query_y1=65535;
    do tick();while(!got_result);
    if(!frame_valid)$fatal(1,"query destroyed frame");
   end
  end
  if(seen!=F*Q)$fatal(1,"query count");
  $display("PASS integral_image %d frames %d queries",F,seen);$finish;
 end
endmodule'''

def run_profile(w,h,b,frames=None,all_cells=True):
 r=random.Random(991+w*31+h*7+b);m=(1<<b)-1
 if frames is None:
  frames=[[[0]*w for _ in range(h)],[[m]*w for _ in range(h)],[[r.randrange(m+1)for _ in range(w)]for _ in range(h)],[[m if (x+y)%3==0 else 1 for x in range(w)]for y in range(h)]]
 rects=[]
 if all_cells:
  rects += [(0,0,x,y)for y in range(h+1)for x in range(w+1)]
  rects += [(x,y,x+1,y+1)for y in range(h)for x in range(w)]
 rects += [(0,0,w,h),(0,0,0,0),(w,h,w,h),(0,h,w,h),(w,0,w,h)]
 for _ in range(40):
  a,bx=sorted([r.randrange(w+1),r.randrange(w+1)]);c,d=sorted([r.randrange(h+1),r.randrange(h+1)]);rects.append((a,c,bx,d))
 rects += [(1,0,0,h),(0,1,w,0),(0,0,w+1,h),(0,0,w,h+1),(65535,0,65535,h)]
 pix=[];rs=[];answers=[];cv_cells=0
 for a in frames:
  cs,cq=cumulative(a)
  cv_s,cv_q=cv2.integral2(np.asarray(a,dtype=np.float64),sdepth=cv2.CV_64F,sqdepth=cv2.CV_64F)
  assert np.array_equal(cv_s,np.array(cs,dtype=np.float64)) and np.array_equal(cv_q,np.array(cq,dtype=np.float64))
  cv_cells+=(w+1)*(h+1)
  pix.extend(v for row in a for v in row)
  for rect in rects:
   x0,y0,x1,y1=rect;rs.append(x0|(y0<<16)|(x1<<32)|(y1<<48))
   su,sq,count,err=rectangle(a,rect)
   if not err:
    assert su==cs[y1][x1]-cs[y1][x0]-cs[y0][x1]+cs[y0][x0]
    assert sq==cq[y1][x1]-cq[y1][x0]-cq[y0][x1]+cq[y0][x0]
   answers.append(su|(sq<<32)|(count<<72)|(err<<104)|(err<<105))
 with tempfile.TemporaryDirectory(prefix='integral_test_')as td:
  d=Path(td);tb=TB
  for name,values in [('PIX',pix),('RECT',rs),('ANS',answers)]:
   p=d/(name+'.mem');p.write_text('\n'.join(f'{v:x}'for v in values)+'\n');tb=tb.replace('"'+name+'"','"'+p.as_posix()+'"')
  import re
  for key,value in [('WW',w),('HH',h),('BB',b),('FF',len(frames)),('QQ',len(rects))]:tb=re.sub(r'\b'+key+r'\b',str(value),tb)
  (d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,d/'compile.log')
  text=execute(['vvp',d/'a.vvp'],ROOT,d/'run.log',timeout=180);print(text.strip())
 return dict(width=w,height=h,bits=b,frames=len(frames),queries=len(answers),all_integral_cells_queried=all_cells,all_pixel_cells_reconstructed=all_cells,actual_opencv_integral2_cells=cv_cells,opencv_version=cv2.__version__)

if __name__=='__main__':
 profiles=[run_profile(*p)for p in [(1,1,8),(1,7,10),(7,1,12),(7,5,8),(8,6,10),(9,7,12),(32,24,12)]]
 e=dict(result='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),oracle='independent Python integer cumulative sums + direct pixel rectangle sums; actual cv2.integral2 full-array equality',profiles=profiles,total_frames=sum(p['frames']for p in profiles),total_queries=sum(p['queries']for p in profiles))
 (H/'test_result.json').write_text(json.dumps(e,indent=2)+'\n')
