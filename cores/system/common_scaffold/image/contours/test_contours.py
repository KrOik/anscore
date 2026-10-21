"""Independent directed cell-edge graph oracle and real skimage topology audit."""
import os,json,random,tempfile,subprocess
from pathlib import Path
import numpy as np
import skimage
from skimage.measure import label,euler_number
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
STEP=[(1,0),(0,1),(-1,0),(0,-1)]
def oracle(mask,w,h):
 # Construct graph independently by emitting each foreground cell's exposed sides.
 def fg(x,y):return 0<=x<w and 0<=y<h and mask[y*w+x]
 edges=set()
 for y in range(h):
  for x in range(w):
   if fg(x,y):
    if not fg(x,y-1):edges.add((x,y,0))
    if not fg(x+1,y):edges.add((x+1,y,1))
    if not fg(x,y+1):edges.add((x+1,y+1,2))
    if not fg(x-1,y):edges.add((x,y+1,3))
 left=edges.copy();loops=[]
 while left:
  start=min(left,key=lambda e:(e[1],e[0],e[2]));e=start;loop=[]
  while True:
   assert e in left,(e,start)
   left.remove(e);loop.append(e);x,y,d=e;dx,dy=STEP[d];xx,yy=x+dx,y+dy
   candidates=[(xx,yy,q) for q in ((d+1)%4,d,(d+3)%4,(d+2)%4)]
   e=next(q for q in candidates if q in edges)
   if e==start:break
   assert len(loop)<=len(edges)
  area=sum(x*STEP[d][1]-y*STEP[d][0] for x,y,d in loop)
  assert area
  loops.append((loop,area))
 assert sum(area for _,area in loops)==2*sum(mask)
 a=np.array(mask).reshape(h,w);components=int(label(a,connectivity=1).max());holes=components-int(euler_number(a,connectivity=1))
 assert sum(area>0 for _,area in loops)==components
 assert sum(area<0 for _,area in loops)==holes
 return loops
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,s_pixel=0,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;
wire s_ready,m_valid,m_contour_start,m_contour_end,m_hole,done_valid,busy;
wire[XW-1:0]m_x;wire[YW-1:0]m_y;wire[1:0]m_dir,error_code;
wire signed[31:0]m_area2;wire[CW-1:0]m_contour_index,foreground_count,contour_count;
wire[EW-1:0]m_edge_index,edge_count;
contours_cell_edges #(.WIDTH(W),.HEIGHT(H))dut(.*);
integer cycle=0,index=0;reg[255:0]expected[0:TOTAL-1];reg[255:0]observed,last_payload,last_status;reg held=0,dh=0;
always @(negedge clk)begin cycle=cycle+1;ce=cycle%11!=0;m_ready=cycle%7!=0;end
always @(posedge clk)if(rst)begin held=0;dh=0;end else begin
 observed={16'(m_x),16'(m_y),8'(m_dir),8'(m_contour_start),8'(m_contour_end),8'(m_hole),m_area2,32'(m_contour_index),32'(m_edge_index)};
 if(held&&(!m_valid||observed!==last_payload))$fatal(1,"unstable OUT");
 if(dh&&(!done_valid||{error_code,foreground_count,contour_count,edge_count}!==last_status))$fatal(1,"unstable DONE");
 held=m_valid&&(!ce||!m_ready);dh=done_valid&&(!ce||!done_ready);last_payload=observed;last_status={error_code,foreground_count,contour_count,edge_count};
 if(ce&&m_valid&&m_ready)begin if(observed!==expected[index])$fatal(1,"token %d got %h expected %h",index,observed,expected[index]);index=index+1;end
end
task send(input a,b,c);begin @(negedge clk);s_pixel=a;s_sof=b;s_eol=c;s_valid=1;@(posedge clk);while(!s_ready)@(posedge clk);@(negedge clk);s_valid=0;end endtask
initial begin $readmemh("expected.hex",expected);repeat(3)@(negedge clk);rst=0;
BODY
if(index!=TOTAL)$fatal(1,"total");$display("PASS");$finish;end
initial begin #100000000;$fatal(1,"timeout");end
endmodule'''
def main():
 rng=random.Random(4328);frames=0;pixels=0;tokens=0;total_loops=0;allholes=0
 with tempfile.TemporaryDirectory(prefix='contours_') as td:
  td=Path(td)
  for w,h in [(1,1),(1,7),(7,1),(2,2),(3,3),(7,7),(11,8)]:
   n=w*h;cases=[]
   if n<=9:cases.extend([[int(v>>i&1) for i in range(n)] for v in range(1<<n)])
   else:
    cases+=[[0]*n,[1]*n,[int((i%w+i//w)%2) for i in range(n)],[int(i%w in (0,w-1) or i//w in (0,h-1)) for i in range(n)]]
    cases.extend([[int(rng.random()<density) for _ in range(n)] for density in [.15,.35,.5,.7,.9] for j in range(8)])
   # Bad marker frames followed by healthy frames prove recovery and zero-output error policy.
   specs=[(a,0) for a in cases]+[([1]*n,1),([0]*n,0),([1]*n,0)]
   body=[];expected=[]
   for mask,err in specs:
    loops=oracle(mask,w,h) if not err else []
    for ci,(loop,area) in enumerate(loops):
     for ei,(x,y,d) in enumerate(loop):
      end=ei==len(loop)-1
      fields=[(x,4),(y,4),(d,2),(int(ei==0),2),(int(end),2),(int(end and area<0),2),(area&0xffffffff if end else 0,8),(ci,8),(ei,8)]
      expected.append(''.join(f'{value:0{digits}x}' for value,digits in fields).zfill(64))
    for i,v in enumerate(mask):body.append(f'send({v},{int(i==0 and not err)},{int(i%w==w-1)});')
    count=sum(len(loop) for loop,_ in loops)
    body.append(f'wait(done_valid);#1;if(error_code!={err}||foreground_count!={sum(mask)}||contour_count!={len(loops)}||edge_count!={count})$fatal(1,"status frame {frames}");repeat(4)@(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);@(negedge clk);done_ready=0;')
    frames+=1;pixels+=n;tokens+=count;total_loops+=len(loops);allholes+=sum(area<0 for _,area in loops)
   tb=TB.replace('module tb;',f'module tb;localparam W={w},H={h},XW={w.bit_length()},YW={h.bit_length()},CW={n.bit_length()},EW={(4*n).bit_length()},TOTAL={max(1,len(expected))};').replace('BODY','\n'.join(body))
   (td/'tb.sv').write_text(tb);(td/'expected.hex').write_text('\n'.join(expected or ['0'*64]))
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'contours_cell_edges.v'),str(td/'tb.sv')],cwd=td,capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   p=subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True,timeout=180)
   if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 result=dict(status='PASS',frames=frames,pixels=pixels,edge_tokens=tokens,contours=total_loops,holes=allholes,skimage_version=skimage.__version__,oracle='independent directed foreground-cell exposed edges, fixed successor permutation',skimage_audit='all valid frames: FG4 component count, BG8 holes via Euler, exact pixel area')
 (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
if __name__=='__main__':
 main()
 from test_contours_protocol import main as protocol_main
 protocol_main()
