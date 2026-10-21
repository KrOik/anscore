from pathlib import Path
import sys,tempfile,random,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def lift(line,inverse=False):
 n=len(line);low=(n+1)//2;out=[0]*n
 for i in range(n//2):
  if inverse:
   s,d=line[i],line[low+i];a=s-d//2;out[2*i]=a;out[2*i+1]=a+d
  else:
   a,b=line[2*i:2*i+2];d=b-a;out[i]=a+d//2;out[low+i]=d
 if n%2:out[-1 if inverse else n//2]=line[n//2 if inverse else -1]
 return out
def model(data,w,h,inverse=False):
 a=[data[y*w:(y+1)*w] for y in range(h)]
 for horizontal in ((False,True) if inverse else (True,False)):
  if horizontal:a=[lift(row,inverse) for row in a]
  else:
   columns=[lift([a[y][x] for y in range(h)],inverse) for x in range(w)]
   a=[[columns[x][y] for x in range(w)] for y in range(h)]
 return [x for row in a for x in row]
def run(w,h,bits):
 n=w*h;cw=bits+3;mask=(1<<cw)-1;lo=-(1<<(bits-1));hi=(1<<(bits-1))-1;r=random.Random(w*91+h+bits)
 images=[[0]*n,[hi]*n,[lo]*n,[hi if i%2 else lo for i in range(n)],[-1 if i%2 else 0 for i in range(n)],[r.randint(lo,hi) for _ in range(n)]]
 transformed=[model(a,w,h) for a in images]
 assert all(model(b,w,h,True)==a for a,b in zip(images,transformed))
 with tempfile.TemporaryDirectory(prefix='haar2d_') as td:
  p=Path(td)
  for name,values in [('in.mem',[x for a in images for x in a]),('out.mem',[x for a in transformed for x in a])]:
   (p/name).write_text('\n'.join(f'{v&mask:x}' for v in values))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,cv=0,inv=0,sv=0,sof=0,eol=0,mr=0;reg signed [{cw-1}:0] sd;
 wire cr,cd,sr,mv,ms,me,busy,done;wire signed [{cw-1}:0] md;wire [3:0] error;
 haar2d_lifting #(.WIDTH({w}),.HEIGHT({h}),.PIXEL_BITS({bits})) dut(clk,rst,ce,cv,inv,cr,cd,sd,sv,sof,eol,sr,md,mv,ms,me,mr,busy,done,error);
 reg [{cw-1}:0] im[0:{6*n-1}],om[0:{6*n-1}],actual[0:{n-1}];
 integer frame,phase,ii,oo,ticks=0;reg [31:0] rng=91;reg stalled=0,take;reg [{cw+1}:0] held;
 always @(posedge clk) begin ticks=ticks+1;if(ticks>100000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||{{md,ms,me}}!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held={{md,ms,me}};end else stalled=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 task configure;input mode;begin ce=1;cv=1;inv=mode;@(negedge clk);if(!cd) $fatal(1,"config");cv=0;end endtask
 task badfirst;input signed [{cw-1}:0] value;input first;input [3:0] expected_error;begin
 ce=1;sv=1;sd=value;sof=first;eol={int(w==1)};@(negedge clk);sv=0;
 if(error!=expected_error||!done||busy||mv) $fatal(1,"bad frame");end endtask
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);repeat(3) @(negedge clk);rst=1;
 // Recovery after marker and range failures must accept a fresh SOF.
 badfirst(0,0,1);badfirst({hi+1},1,2);
 ce=1;sv=1;sd=0;sof=1;eol={int(w!=1)};@(negedge clk);sv=0;if(error!=1||!done) $fatal(1,"bad EOL");
 for(frame=0;frame<6;frame=frame+1) for(phase=0;phase<2;phase=phase+1) begin
 configure(phase);ii=0;oo=0;
 while(oo<{n}) begin
 if(ii<{n}) begin if(!sv) sv=rng[4]|rng[5];sd=phase?actual[ii]:im[frame*{n}+ii];sof=ii==0;eol=ii%{w}=={w-1};end else sv=0;
 @(posedge clk);take=ce&&sv&&sr;if(take) ii=ii+1;
 if(ce&&mv&&mr) begin
 if(md!==(phase?im[frame*{n}+oo]:om[frame*{n}+oo])||ms!==(oo==0)||me!==(oo%{w}=={w-1})) $fatal(1,"numeric phase=%0d idx=%0d",phase,oo);
 if(!phase) actual[oo]=md;oo=oo+1;end
 tick;if(take) sv=0;
 end
 sv=0;if(error||busy||!done) $fatal(1,"terminal");
 end
 // Pathological inverse coefficients must error before emitting a frame.
 configure(1);ce=1;mr=1;
 for(ii=0;ii<{n};ii=ii+1) begin sv=1;sd={(1<<(cw-1))-1};sof=ii==0;eol=ii%{w}=={w-1};@(negedge clk);end sv=0;
 while(!done) begin @(negedge clk);if(mv) $fatal(1,"invalid inverse leaked output");end
 if(error!=3||busy) $fatal(1,"inverse range check");
 // Abort computation/partial capture and verify reset dominates CE.
 configure(0);ce=1;sv=1;sd=0;sof=1;eol={int(w==1)};@(negedge clk);sv=0;ce=0;rst=0;@(negedge clk);if(busy||mv||error) $fatal(1,"reset");
 $display("PASS Haar {w}x{h} bits={bits} 6 real RTL forward/inverse roundtrips/errors/CE/reset");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'haar2d_lifting.sv',p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS Haar' in text;print(text.strip())
 return {'width':w,'height':h,'pixel_bits':bits,'frames':12,'real_rtl_roundtrips':6,'outputs':12*n,'result':'PASS'}
if __name__=='__main__':
 results=[run(w,h,b) for w,h,b in ((1,1,8),(1,7,8),(8,1,8),(3,5,8),(8,6,12),(7,7,16))]
 for parameter,value in [('WIDTH',0),('HEIGHT',0),('COEFF_W',8),('PIXEL_BITS',17)]:
  with tempfile.TemporaryDirectory(prefix='haar_invalid_') as td:
   p=Path(td)
   execute(['iverilog','-g2012','-s','haar2d_lifting','-P',f'haar2d_lifting.{parameter}={value}','-o',p/'sim',HERE/'haar2d_lifting.sv'],p,p/'compile.log')
   try:execute(['vvp',p/'sim'],p,p/'run.log')
   except RuntimeError as exc:assert 'invalid Haar parameters' in str(exc)
   else:raise AssertionError('invalid parameter accepted')
   results.append({'invalid_parameter':parameter,'value':value,'result':'REJECTED'})
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
