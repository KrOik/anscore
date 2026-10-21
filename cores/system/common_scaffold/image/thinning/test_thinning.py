from pathlib import Path
import sys,tempfile,random,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def zhang(image,w,h,limit):
 a=list(image)
 def get(x,y):return int(a[y*w+x]) if 0<=x<w and 0<=y<h else 0
 for iteration in range(1,limit+1):
  changed=False
  for phase in (0,1):
   deleted=[]
   for y in range(h):
    for x in range(w):
     if not get(x,y):continue
     p=[get(x,y-1),get(x+1,y-1),get(x+1,y),get(x+1,y+1),get(x,y+1),get(x-1,y+1),get(x-1,y),get(x-1,y-1)]
     neighbors=sum(p);transitions=sum(not p[i] and p[(i+1)%8] for i in range(8))
     triples=((0,2,4),(2,4,6)) if phase==0 else ((0,2,6),(0,4,6))
     if 2<=neighbors<=6 and transitions==1 and all(not all(p[i] for i in triple) for triple in triples):deleted.append(y*w+x)
   for i in deleted:a[i]=0
   changed=changed or bool(deleted)
  if not changed:return a,iteration,True
 return a,limit,False
def run(w,h,limit):
 n=w*h;r=random.Random(w*51+h)
 patterns=[[0]*n,[1]*n,
 [int(y==h//2) for y in range(h) for x in range(w)],
 [int(x==w//2 or y==h//2) for y in range(h) for x in range(w)],
 [int(x in (0,w-1) or y in (0,h-1)) for y in range(h) for x in range(w)],
 [int(1<=x<w-1 and 1<=y<h-1) for y in range(h) for x in range(w)],
 [r.randrange(2) for i in range(n)],[int(r.randrange(4)==0) for i in range(n)],
 [int(x==y or x==y+1) for y in range(h) for x in range(w)]]
 results=[zhang(p,w,h,limit) for p in patterns]
 comparison=None
 if limit==64:
  try:
   import numpy as np
   from skimage.morphology import skeletonize
  except ImportError:comparison={'status':'unavailable'}
  else:
   differences=[int(np.count_nonzero(skeletonize(np.array(image,dtype=bool).reshape(h,w),method='zhang')!=np.array(result,dtype=bool).reshape(h,w))) for image,(result,_,_) in zip(patterns,results)]
   comparison={'status':'compared','different_pixels_per_fixture':differences,'note':'diagnostic comparison only; public LUT variant can differ from explicit two-phase rules'}
 with tempfile.TemporaryDirectory(prefix='thinning_') as td:
  p=Path(td)
  def mem(name,values): (p/name).write_text('\n'.join(f'{v:x}' for v in values))
  mem('in.mem',[int(v) for a in patterns for v in a]);mem('out.mem',[int(v) for a,_,_ in results for v in a]);mem('iterations.mem',[i for _,i,_ in results]);mem('converged.mem',[int(c) for _,_,c in results])
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,sv=0,pixel=0,sof=0,eol=0,mr=0;
 wire sr,mp,mv,ms,me,busy,done,converged;wire [15:0] iterations;wire [3:0] error;
 zhang_suen_thinning #(.WIDTH({w}),.HEIGHT({h}),.MAX_ITERATIONS({limit})) dut(clk,rst,ce,pixel,sv,sof,eol,sr,mp,mv,ms,me,mr,busy,done,converged,iterations,error);
 reg im[0:{9*n-1}],om[0:{9*n-1}],conv[0:8];reg [15:0] its[0:8];reg [2:0] held;
 integer f,i,ii,oo,ticks=0;reg [31:0] rng=172;reg stalled=0,take;
 always @(posedge clk) begin ticks=ticks+1;if(ticks>500000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||{{mp,ms,me}}!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held={{mp,ms,me}};end else stalled=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);$readmemh("iterations.mem",its);$readmemh("converged.mem",conv);
 repeat(3) @(negedge clk);rst=1;
 // Marker errors recover to fresh-frame capture without resetting.
 ce=1;sv=1;pixel=1;sof=0;eol=0;@(negedge clk);sv=0;if(error!=1||!done||busy||mv) $fatal(1,"SOF error");
 sv=1;sof=1;eol={int(w!=1)};@(negedge clk);sv=0;if(error!=1||!done) $fatal(1,"EOL error");
 // Abort after RAM processing has begun; old banks must not affect new input.
 for(i=0;i<{n};i=i+1) begin sv=1;pixel=1;sof=i==0;eol=i%{w}=={w-1};@(negedge clk);end sv=0;
 repeat(25) @(negedge clk);ce=0;rst=0;@(negedge clk);if(mv||busy||error) $fatal(1,"compute reset");rst=1;ce=1;
 for(f=0;f<9;f=f+1) begin ii=0;oo=0;
 while(oo<{n}) begin
 if(ii<{n}) begin if(!sv) sv=rng[4]|rng[5];pixel=im[f*{n}+ii];sof=ii==0;eol=ii%{w}=={w-1};end else sv=0;
 @(posedge clk);take=ce&&sv&&sr;if(take) ii=ii+1;
 if(ce&&mv&&mr) begin
 if(mp!==om[f*{n}+oo]||ms!==(oo==0)||me!==(oo%{w}=={w-1})) $fatal(1,"numeric f=%0d i=%0d",f,oo);
 if(converged!==conv[f]||iterations!==its[f]||error!==(conv[f]?4'd0:4'd2)) $fatal(1,"convergence f=%0d",f);
 oo=oo+1;end
 tick;if(take) sv=0;
 end
 sv=0;if(busy||!done) $fatal(1,"terminal");
 end
 ce=1;mr=0;
 for(i=0;i<{n};i=i+1) begin sv=1;pixel=0;sof=i==0;eol=i%{w}=={w-1};@(negedge clk);end sv=0;
 while(!mv) @(negedge clk);
 ce=0;rst=0;@(negedge clk);if(mv||busy||error) $fatal(1,"stalled output reset");
 $display("PASS Zhang-Suen {w}x{h} MAX={limit} 9frames simultaneous/borders/convergence/reset/CE");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'zhang_suen_thinning.sv',p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS Zhang' in text;print(text.strip())
 return {'width':w,'height':h,'max_iterations':limit,'frames':9,'outputs':9*n,'converged_frames':sum(c for _,_,c in results),'not_converged_frames':sum(not c for _,_,c in results),'skimage_comparison':comparison,'result':'PASS'}
if __name__=='__main__':
 results=[run(*a) for a in ((1,1,64),(1,7,64),(8,1,64),(7,7,64),(8,6,64),(7,7,1),(9,9,2))]
 assert sum(a['not_converged_frames'] for a in results)>0
 for args in ((0,16,64),(16,0,64),(16,16,0),(65535,65535,64)):
  with tempfile.TemporaryDirectory(prefix='thin_invalid_') as td:
   p=Path(td);w,h,limit=args
   execute(['iverilog','-g2012','-s','zhang_suen_thinning','-P',f'zhang_suen_thinning.WIDTH={w}','-P',f'zhang_suen_thinning.HEIGHT={h}','-P',f'zhang_suen_thinning.MAX_ITERATIONS={limit}','-o',p/'sim',HERE/'zhang_suen_thinning.sv'],p,p/'compile.log')
   try:execute(['vvp',p/'sim'],p,p/'run.log')
   except RuntimeError as exc:assert 'invalid thinning parameters' in str(exc)
   else:raise AssertionError('invalid parameters accepted')
   results.append({'invalid_parameters':args,'result':'REJECTED'})
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
