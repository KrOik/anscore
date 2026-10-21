from pathlib import Path
from collections import deque
import sys,tempfile,random,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def bfs(pixels,w,h,mode):
 distance=[None]*(w*h);queue=deque()
 for i,p in enumerate(pixels):
  if p==0:distance[i]=0;queue.append(i)
 neighbors=[(-1,0),(1,0),(0,-1),(0,1)]
 if mode:neighbors += [(-1,-1),(-1,1),(1,-1),(1,1)]
 while queue:
  i=queue.popleft();x,y=i%w,i//w
  for dx,dy in neighbors:
   a,b=x+dx,y+dy
   if 0<=a<w and 0<=b<h and distance[b*w+a] is None:
    distance[b*w+a]=distance[i]+1;queue.append(b*w+a)
 return distance
def run(w,h):
 r=random.Random(w*193+h);n=w*h;dw=(w+h).bit_length();inf=(1<<dw)-1
 patterns=[[0]*n,[1]*n,[0]+[1]*(n-1),[1]*(n//2)+[0]+[1]*(n-n//2-1),[r.randrange(2) for _ in range(n)],[r.randrange(4)!=0 for _ in range(n)]]
 inputs=[];outputs=[]
 for mode in (0,1):
  for image in patterns:
   result=bfs(image,w,h,mode)
   inputs += [(int(p)<<2)|(int(i==0)<<1)|int(i%w==w-1) for i,p in enumerate(image)]
   outputs += [((inf if d is None else d)<<3)|(int(d is None)<<2)|(int(i==0)<<1)|int(i%w==w-1) for i,d in enumerate(result)]
 with tempfile.TemporaryDirectory(prefix='distance_transform_') as td:
  p=Path(td)
  for name,values in [('in.mem',inputs),('out.mem',outputs)]: (p/name).write_text('\n'.join(f'{v:x}' for v in values))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,cv=0,mode=0,sv=0,mr=0;reg [2:0] sd;
 wire cr,cd,sr,mv,invalid,sof,eol,busy,noseed;wire [3:0] error;wire [{dw-1}:0] distance;
 binary_distance_transform #(.WIDTH({w}),.HEIGHT({h})) dut(clk,rst,ce,cv,mode,cr,cd,sd[2],sv,sd[1],sd[0],sr,distance,invalid,mv,sof,eol,mr,busy,noseed,error);
 wire [{dw+2}:0] payload={{distance,invalid,sof,eol}};
 reg [2:0] im[0:{len(inputs)-1}];reg [{dw+2}:0] om[0:{len(outputs)-1}];reg [{dw+2}:0] held;
 integer f,ii,oo,ticks=0;reg [31:0] rng=81;reg stalled=0,take;
 always @(posedge clk) begin ticks=ticks+1;if(ticks>100000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||payload!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held=payload;end else stalled=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);
 repeat(3) @(negedge clk);rst=1;sd={{1'b1,1'b1,1'b{int(w==1)}}};sv=1;@(negedge clk);sv=0;rst=0;@(negedge clk);rst=1;
 for(f=0;f<12;f=f+1) begin
 ce=1;cv=1;mode=f>=6;@(negedge clk);if(!cd) $fatal(1,"config");cv=0;ii=0;oo=0;
 while(oo<{n}) begin
 if(ii<{n}) begin if(!sv) sv=rng[4]|rng[5];sd=im[f*{n}+ii];end else sv=0;
 @(posedge clk);take=ce&&sv&&sr;if(take) ii=ii+1;
 if(ce&&mv&&mr) begin if(payload!==om[f*{n}+oo]) $fatal(1,"numeric frame=%0d pixel=%0d got=%h expected=%h",f,oo,payload,om[f*{n}+oo]);oo=oo+1;end
 tick;if(take) sv=0;
 end
 sv=0;if(busy||error||noseed!==om[f*{n}][2]) $fatal(1,"terminal");
 end
 ce=1;sv=1;sd=0;@(negedge clk);sv=0;if(error!=1||sr||mv) $fatal(1,"marker error");
 repeat(3) @(negedge clk);if(sr||error!=1) $fatal(1,"failstop");
 ce=0;rst=0;@(negedge clk);if(error||busy||mv) $fatal(1,"reset");
 ce=1;rst=1;sv=1;sd={{1'b1,1'b1,1'b{int(w!=1)}}};@(negedge clk);sv=0;
 if(error!=1||sr||mv) $fatal(1,"EOL mismatch");
 $display("PASS distance {w}x{h} L1/Linf BFS 12frames CE/stall/marker/reset");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'binary_distance_transform.sv',p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS distance' in text;print(text.strip())
 return {'width':w,'height':h,'frames':12,'outputs':n*12,'result':'PASS'}
if __name__=='__main__':
 results=[run(w,h) for w,h in ((1,1),(1,7),(8,1),(3,5),(8,6),(7,7))]
 for parameter,value in [('WIDTH',0),('HEIGHT',0),('DIST_W',1)]:
  with tempfile.TemporaryDirectory(prefix='distance_invalid_') as td:
   p=Path(td)
   execute(['iverilog','-g2012','-s','binary_distance_transform','-P',f'binary_distance_transform.{parameter}={value}','-o',p/'sim',HERE/'binary_distance_transform.sv'],p,p/'compile.log')
   try:execute(['vvp',p/'sim'],p,p/'run.log')
   except RuntimeError as exc:assert 'invalid distance geometry/width' in str(exc)
   else:raise AssertionError('invalid parameter accepted')
   results.append({'invalid_parameter':parameter,'value':value,'result':'REJECTED'})
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
