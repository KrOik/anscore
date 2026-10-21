import os,json,tempfile,subprocess,heapq,random
from pathlib import Path
import numpy as np
import skimage
from skimage.segmentation import watershed
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
def oracle(a,seeds,mask,w,h,c8):
 labels=seeds.copy();q=[];age=w*h
 for i,v in enumerate(labels):
  if v and mask[i]:heapq.heappush(q,(a[i],i,i))
 count=len(q);pops=0
 while q:
  _,_,i=heapq.heappop(q);pops+=1;x=i%w;y=i//w
  for dx,dy in [(0,-1),(-1,0),(1,0),(0,1)]+([(-1,-1),(1,-1),(-1,1),(1,1)] if c8 else []):
   xx=x+dx;yy=y+dy
   if 0<=xx<w and 0<=yy<h:
    j=yy*w+xx
    if mask[j] and not labels[j]:labels[j]=labels[i];heapq.heappush(q,(a[j],age,j));age+=1;count+=1
 return labels,count,pops
def main():
 rng=random.Random(781);frames=0;pixels=0;skmatch=0;skdiff=0
 with tempfile.TemporaryDirectory(prefix='watershed_') as td:
  td=Path(td)
  for w,h,bits,lb in [(1,1,8,8),(1,7,8,8),(7,1,8,8),(4,5,8,8),(7,7,8,8),(4,5,12,16)]:
   body=[];expected=[]
   for case in range(22):
    n=w*h;c8=case%2;a=list(range(n));rng.shuffle(a)
    if case>=8:a=[rng.randrange(4) for _ in range(n)]
    if bits==12:a=[v*71 for v in a]
    mask=[int(rng.random()>.2) for _ in range(n)];seeds=[0]*n
    for j in rng.sample(range(n),min(n,3)):mask[j]=1;seeds[j]=j%7+1
    if case==18:seeds=[i+1 for i in range(n)];mask=[1]*n
    if case==19:a=[n-i for i in range(n)];mask=[1]*n;seeds=[0]*(n-1)+[7]
    if case==20:mask=[int(i%w!=w//2) for i in range(n)];seeds=[0]*n;seeds[0]=1;mask[0]=1
    if case==21:mask=[1]*n;seeds=[0]*n;seeds[0]=1
    if lb==16:seeds=[v+60000 if v else 0 for v in seeds]
    if case==16:seeds=[0]*n
    if case==17:mask[0]=0;seeds[0]=3
    err=(1 if case==21 else 0)|(2 if any(v and not mask[i] for i,v in enumerate(seeds)) else 0)|(4 if not any(v and mask[i] for i,v in enumerate(seeds)) else 0)
    labels,assigned,popped=oracle(a,seeds,mask,w,h,c8) if not err else (seeds,sum(bool(v and mask[i]) for i,v in enumerate(seeds)),0)
    if not err:
     sk=watershed(np.array(a).reshape(h,w),np.array(seeds).reshape(h,w),connectivity=2 if c8 else 1,mask=np.array(mask,dtype=bool).reshape(h,w)).ravel().tolist()
     if sk==labels:skmatch+=1
     else:skdiff+=1
     if case<8:assert sk==labels
    body.append(f'cfg_connect8={c8};')
    for i in range(n):body.append(f'send({a[i]},{seeds[i]},{mask[i]},{int(i==0 and case!=21)},{int(i%w==w-1)}); cfg_connect8={1-c8};')
    for i,v in enumerate(labels):expected.append((v,int(bool(mask[i])),int(bool(err or not mask[i] or not v)),i%w,i//w,int(i==0),int(i%w==w-1),int(i==n-1)))
    body.append(f'wait(done_valid); #1; if(error_code!={err} || assigned_count!={assigned} || popped_count!={popped}) $fatal(1,"status case {case}"); repeat(3) @(negedge clk); done_ready=1; @(posedge clk); while(!ce) @(posedge clk); @(negedge clk); done_ready=0;')
    frames+=1;pixels+=n
   tb='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,cfg_connect8=0,s_valid=0,s_sof=0,s_eol=0,s_domain=0,m_ready=0,done_ready=0;
reg[BITS-1:0] s_elevation=0;reg[LB-1:0]s_seed=0;wire s_ready,m_valid,m_sof,m_eol,m_last,m_domain,m_invalid,done_valid,busy;wire[LB-1:0]m_label;wire[3:0]error_code;
wire[XW-1:0]m_x;wire[YW-1:0]m_y;wire[CW-1:0]seed_count,assigned_count,popped_count;
watershed_priority_frame #(.BITS(BITS),.LABEL_BITS(LB),.WIDTH(W),.HEIGHT(H)) dut(.*);
reg held=0,doneheld=0;reg[127:0]last_payload;reg[127:0]last_status;
always @(posedge clk)if(rst)begin held=0;doneheld=0;end else begin
 if(held&&!m_valid)$fatal(1,"valid dropped");
 if(doneheld&&!done_valid)$fatal(1,"done dropped");
 if(held&&{16'(m_label),m_domain,m_invalid,m_x,m_y,m_sof,m_eol,m_last}!==last_payload)$fatal(1,"output unstable");
 if(doneheld&&{error_code,seed_count,assigned_count,popped_count}!==last_status)$fatal(1,"done unstable");
 held=m_valid&&(!ce||!m_ready);doneheld=done_valid&&(!ce||!done_ready);
 last_payload={16'(m_label),m_domain,m_invalid,m_x,m_y,m_sof,m_eol,m_last};last_status={error_code,seed_count,assigned_count,popped_count};
end
integer cycle=0,index=0;integer fd;reg[127:0] exp[0:TOTAL-1];reg[127:0] observed;
always @(negedge clk)begin cycle=cycle+1;ce=(cycle%11!=0);m_ready=(cycle%7!=0);end
always @(posedge clk)if(!rst&&ce&&m_valid&&m_ready)begin
 observed={48'b0,16'(m_label),7'b0,m_domain,7'b0,m_invalid,8'(m_x),8'(m_y),7'b0,m_sof,7'b0,m_eol,7'b0,m_last};
 if(observed!==exp[index]) $fatal(1,"pixel %d got %h expected %h",index,observed,exp[index]);index=index+1;end
task send(input[BITS-1:0]a,input[LB-1:0]b,input d,f,e);begin @(negedge clk);s_valid=1;s_elevation=a;s_seed=b;s_domain=d;s_sof=f;s_eol=e;@(posedge clk);while(!s_ready)@(posedge clk);@(negedge clk);s_valid=0;end endtask
initial begin $readmemh("expected.hex",exp);repeat(3)@(negedge clk);rst=0;
BODY
if(index!=TOTAL)$fatal; $display("PASS");$finish;end
initial begin #200000000;$fatal(1,"timeout");end
endmodule'''
   tb=tb.replace('module tb;',f'module tb; localparam W={w},H={h},BITS={bits},LB={lb},XW={max(1,(w-1).bit_length())},YW={max(1,(h-1).bit_length())},CW={(w*h).bit_length()},TOTAL={len(expected)};').replace('BODY','\n'.join(body))
   (td/'tb.sv').write_text(tb)
   (td/'expected.hex').write_text('\n'.join((f'{row[0]:04x}'+''.join(f'{v:02x}' for v in row[1:])).zfill(32) for row in expected))
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'watershed_priority_frame.v'),str(td/'tb.sv')],cwd=td,capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   p=subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True,timeout=180)
   if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 result=dict(status='PASS',frames=frames,pixels=pixels,skimage_exact_frames=skmatch,skimage_tie_difference_frames=skdiff,skimage_version=skimage.__version__,reference="heapq raw elevation, seed age=raster index, discovery age=N++",protocol="CE/stalls, held OUT/DONE, malformed marker recovery, config snapshot",parameter_sets="B8/L8 and B12/L16",testbench_note="Initial TB DONE pulse could coincide CE0; corrected to wait for accepted handshake. Superseded run cancelled and temporary directory removed.")
 (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
if __name__=='__main__':
 main()
 from test_watershed_protocol import main as protocol_main
 protocol_main()

