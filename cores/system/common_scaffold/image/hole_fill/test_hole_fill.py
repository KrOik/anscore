from pathlib import Path
from collections import deque
import sys,tempfile,random,json
import numpy as np
from scipy.ndimage import binary_fill_holes
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def flood(image,w,h,connect8):
 reached=set();queue=deque()
 for y in range(h):
  for x in range(w):
   i=y*w+x
   if not image[i] and (x==0 or y==0 or x==w-1 or y==h-1):reached.add(i);queue.append(i)
 neighbors=[(-1,0),(1,0),(0,-1),(0,1)]
 if connect8:neighbors += [(-1,-1),(-1,1),(1,-1),(1,1)]
 while queue:
  i=queue.popleft();x,y=i%w,i//w
  for dx,dy in neighbors:
   a,b=x+dx,y+dy;j=b*w+a
   if 0<=a<w and 0<=b<h and not image[j] and j not in reached:reached.add(j);queue.append(j)
 filled=[int(bool(p) or i not in reached) for i,p in enumerate(image)]
 holes=[int(not p and i not in reached) for i,p in enumerate(image)]
 return filled,holes
def run(w,h,conn):
 n=w*h;r=random.Random(w*73+h)
 patterns=[[0]*n,[1]*n,
 [int(x in (0,w-1) or y in (0,h-1)) for y in range(h) for x in range(w)],
 [int(x==w//2 or y==h//2) for y in range(h) for x in range(w)],
 [int(1<=x<w-1 and 1<=y<h-1) for y in range(h) for x in range(w)],
 [int(not(0<x<w-1 and 0<y<h-1 and x%2 and y%2)) for y in range(h) for x in range(w)],
 [int(x!=y) for y in range(h) for x in range(w)],
 [r.randrange(2) for i in range(n)],[int(r.randrange(4)==0) for i in range(n)],
 [int((x in (0,w-1) or y in (0,h-1)) and not(x==w//2 and y==0)) for y in range(h) for x in range(w)]]
 results=[flood(image,w,h,conn) for image in patterns]
 structure=np.ones((3,3),bool) if conn else np.array([[0,1,0],[1,1,1],[0,1,0]],bool)
 for image,(filled,_) in zip(patterns,results):
  assert list(binary_fill_holes(np.array(image,bool).reshape(h,w),structure=structure).astype(int).ravel())==filled
 with tempfile.TemporaryDirectory(prefix='hole_fill_') as td:
  p=Path(td)
  def mem(name,values): (p/name).write_text('\n'.join(f'{v:x}' for v in values))
  mem('in.mem',[int(v) for a in patterns for v in a]);mem('out.mem',[(f<<1)|hole for filled,holes in results for f,hole in zip(filled,holes)]);mem('counts.mem',[sum(holes) for _,holes in results])
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,pixel=0,sv=0,sof=0,eol=0,mr=0;
 wire sr,mp,mh,mv,ms,me,busy,done;wire [31:0] count;wire [3:0] error;
 binary_hole_fill #(.WIDTH({w}),.HEIGHT({h}),.CONNECT8({conn})) dut(clk,rst,ce,pixel,sv,sof,eol,sr,mp,mh,mv,ms,me,mr,busy,done,count,error);
 reg im[0:{10*n-1}];reg [1:0] om[0:{10*n-1}];reg [31:0] counts[0:9];reg [3:0] held;
 integer f,i,ii,oo,ticks=0;reg [31:0] rng=716;reg stalled=0,take;
 always @(posedge clk) begin ticks=ticks+1;if(ticks>200000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||{{mp,mh,ms,me}}!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held={{mp,mh,ms,me}};end else stalled=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);$readmemh("counts.mem",counts);repeat(3) @(negedge clk);rst=1;
 sv=1;sof=0;eol=0;@(negedge clk);sv=0;if(error!=1||!done||busy||mv) $fatal(1,"SOF error");
 sv=1;sof=1;eol={int(w!=1)};@(negedge clk);sv=0;if(error!=1||!done) $fatal(1,"EOL error");
 if({n}>1) begin
 sv=1;pixel=0;sof=1;eol={int(w==1)};@(negedge clk);sv=0;
 sv=1;sof=1;eol=0;@(negedge clk);sv=0;if(error!=1||!done||busy) $fatal(1,"partial capture error");
 end
 // Full capture resets after queue processing starts; no stale visited/queue state.
 for(i=0;i<{n};i=i+1) begin sv=1;pixel=0;sof=i==0;eol=i%{w}=={w-1};@(negedge clk);end sv=0;
 repeat(5) @(negedge clk);ce=0;rst=0;@(negedge clk);if(mv||busy||error||count) $fatal(1,"processing reset");rst=1;ce=1;
 for(f=0;f<10;f=f+1) begin ii=0;oo=0;
 while(oo<{n}) begin
 if(ii<{n}) begin if(!sv) sv=rng[4]|rng[5];pixel=im[f*{n}+ii];sof=ii==0;eol=ii%{w}=={w-1};end else sv=0;
 @(posedge clk);take=ce&&sv&&sr;if(take) ii=ii+1;
 if(ce&&mv&&mr) begin if({{mp,mh}}!==om[f*{n}+oo]||ms!==(oo==0)||me!==(oo%{w}=={w-1})||error) $fatal(1,"numeric f=%0d i=%0d",f,oo);
 if(f==0&&dut.tail!={n}) $fatal(1,"full capacity coverage");oo=oo+1;end
 tick;if(take) sv=0;
 end
 sv=0;if(error||busy||!done||count!==counts[f]) $fatal(1,"terminal count=%0d exp=%0d",count,counts[f]);
 end
 // A pending output is reset while CE is disabled.
 ce=1;mr=0;for(i=0;i<{n};i=i+1) begin sv=1;pixel=1;sof=i==0;eol=i%{w}=={w-1};@(negedge clk);end sv=0;
 while(!mv) @(negedge clk);ce=0;rst=0;@(negedge clk);if(mv||busy||error) $fatal(1,"output reset");
 $display("PASS hole fill {w}x{h} CONNECT8={conn}:10frames flood/scipy/fullcapacity/CE/reset");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'binary_hole_fill.sv',p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS hole' in text;print(text.strip())
 return {'width':w,'height':h,'connectivity':8 if conn else 4,'frames':10,'outputs':10*n,'filled_counts':[sum(hole) for _,hole in results],'scipy_comparison':'exact PASS','result':'PASS'}
if __name__=='__main__':
 results=[run(*args) for args in ((1,1,0),(1,1,1),(1,7,0),(8,1,1),(7,7,0),(7,7,1),(8,6,0),(8,6,1))]
 assert results[4]['filled_counts'][6]!=results[5]['filled_counts'][6]
 for w,h,c in ((0,16,0),(16,0,0),(16,16,2),(65535,65535,0)):
  with tempfile.TemporaryDirectory(prefix='hole_invalid_') as td:
   p=Path(td)
   execute(['iverilog','-g2012','-s','binary_hole_fill','-P',f'binary_hole_fill.WIDTH={w}','-P',f'binary_hole_fill.HEIGHT={h}','-P',f'binary_hole_fill.CONNECT8={c}','-o',p/'sim',HERE/'binary_hole_fill.sv'],p,p/'compile.log')
   try:execute(['vvp',p/'sim'],p,p/'run.log')
   except RuntimeError as exc:assert 'invalid hole-fill parameters' in str(exc)
   else:raise AssertionError('invalid parameters accepted')
   results.append({'invalid_parameters':[w,h,c],'result':'REJECTED'})
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
