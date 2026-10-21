from pathlib import Path
import sys,tempfile,random,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def run(w,h,bits,length,radius):
 r=random.Random(w*71+h+length);n=w*h
 patterns=[[(0,0,0,0)]+[tuple(r.randint(-radius,radius) for _ in range(4)) for i in range(length-1)] for _ in range(2)]
 images=[[77]*n,[r.randrange(1<<bits) for i in range(n)],[((i%w)*31+(i//w)*97)% (1<<bits) for i in range(n)]]
 keys=[(radius,radius),(w-radius-1,h-radius-1),(w//2,h//2),(0,0),(w-1,h-1),(65535,65535)]
 keys += [(r.randrange(w),r.randrange(h)) for _ in range(4)]
 expected=[];invalid=[]
 for f,image in enumerate(images):
  pattern=patterns[int(f==2)]
  for x,y in keys:
   bad=x<radius or y<radius or x+radius>=w or y+radius>=h
   descriptor=0
   if not bad:
    for i,(ax,ay,bx,by) in enumerate(pattern):descriptor |= int(image[(y+ay)*w+x+ax]<image[(y+by)*w+x+bx])<<i
   expected.append(descriptor);invalid.append(int(bad))
 with tempfile.TemporaryDirectory(prefix='brief_') as td:
  p=Path(td)
  def mem(name,values): (p/name).write_text('\n'.join(f'{v:x}' for v in values))
  mem('pixels.mem',[v for image in images for v in image]);mem('expected.mem',expected);mem('invalid.mem',invalid)
  mem('pattern.mem',[sum((v&255)<<(24-8*i) for i,v in enumerate(pair)) for pattern in patterns for pair in pattern])
  mem('keys.mem',[(x<<16)|y for x,y in keys])
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,pv=0,cv=0,sv=0,sof=0,eol=0,kv=0,rel=0,mr=0;
 reg [7:0] pi;reg [31:0] pd;reg [{bits-1}:0] pixel;reg [15:0] kx,ky,kid;
 wire pr,cr,cd,er,sr,kr,rr,loaded,mv,invalid;wire [{length-1}:0] descriptor;wire [15:0] mx,my,mid;wire [3:0] error;
 brief_descriptor #(.WIDTH({w}),.HEIGHT({h}),.BITS({bits}),.DESC_BITS({length}),.RADIUS({radius})) dut(clk,rst,ce,pv,pr,pi,pd[31:24],pd[23:16],pd[15:8],pd[7:0],cv,cr,cd,er,pixel,sv,sof,eol,sr,kv,kr,kx,ky,kid,rel,rr,loaded,descriptor,invalid,mv,mx,my,mid,mr,error);
 reg [{bits-1}:0] pixels[0:{3*n-1}];reg [31:0] patterns[0:{2*length-1}],keys[0:9];reg [{length-1}:0] expected[0:29];reg bad[0:29];
 integer f,i,k,ticks=0;reg [31:0] rng=88;reg stalled=0,take;reg [{length+48}:0] held;
 always @(posedge clk) begin ticks=ticks+1;if(ticks>100000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||{{descriptor,invalid,mx,my,mid}}!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held={{descriptor,invalid,mx,my,mid}};end else stalled=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 task commit;input reject;begin ce=1;cv=1;@(negedge clk);cv=0;while(!cd&&!er) @(negedge clk);if(reject?(!er||cd):(!cd||er)) $fatal(1,"commit");@(negedge clk);end endtask
 task loadpattern;input bank;begin ce=1;for(i=0;i<{length};i=i+1) begin pv=1;pi=i;pd=patterns[bank*{length}+i];@(negedge clk);if(!pr) $fatal(1,"pattern write");end pv=0;commit(0);end endtask
 initial begin
 $readmemh("pixels.mem",pixels);$readmemh("pattern.mem",patterns);$readmemh("keys.mem",keys);$readmemh("expected.mem",expected);$readmemh("invalid.mem",bad);
 repeat(3) @(negedge clk);rst=1;commit(1);loadpattern(0);
 if({length}==128) begin pv=1;pi=255;pd=0;@(negedge clk);pv=0;if(!er||error!=4) $fatal(1,"pattern index");end
 // Invalid offsets reject atomically; active pattern must remain unchanged.
 pv=1;pi=0;pd=32'h7f000000;@(negedge clk);pv=0;commit(1);
 pv=1;pi=0;pd=patterns[0];@(negedge clk);pv=0;
 // Bad capture invalidates the frame and permits a fresh SOF retry.
 ce=1;sv=1;sof=0;eol=0;pixel=0;@(negedge clk);sv=0;if(error!=3||loaded) $fatal(1,"frame error");
 if({n}>1) begin
 sv=1;sof=1;eol={int(w==1)};@(negedge clk);sv=0;
 sv=1;sof=1;eol=0;@(negedge clk);sv=0;if(error!=3||loaded) $fatal(1,"partial frame error");
 end
 for(f=0;f<3;f=f+1) begin
 if(f==2) loadpattern(1);
 i=0;
 while(i<{n}) begin
 if(!sv) sv=rng[4]|rng[5];pixel=pixels[f*{n}+i];sof=i==0;eol=i%{w}=={w-1};
 @(posedge clk);take=ce&&sv&&sr;if(take) i=i+1;tick;if(take) sv=0;
 end
 if(!loaded||sr||error) $fatal(1,"frame phase");
 for(k=0;k<10;k=k+1) begin
 ce=1;mr=0;kv=1;{{kx,ky}}=keys[k];kid=f*10+k;@(negedge clk);kv=0;
 // A pending update cannot change the current frame's active pattern.
 if(f==1) begin cv=1;pv=1;pi=0;pd=32'h01010101;end
 while(!mv) begin tick;if(cr||pr) $fatal(1,"pattern snapshot");end
 if(descriptor!==expected[f*10+k]||invalid!==bad[f*10+k]||mx!==kx||my!==ky||mid!==kid) $fatal(1,"descriptor f=%0d kp=%0d got=%h exp=%h",f,k,descriptor,expected[f*10+k]);
 while(mv) tick;
 cv=0;pv=0;
 end
 if(f==2) begin
 ce=1;mr=0;kv=1;kx={radius};ky={radius};kid=99;@(negedge clk);kv=0;
 while(!mv) @(negedge clk);
 ce=0;rst=0;@(negedge clk);if(mv||loaded||sr) $fatal(1,"reset pending descriptor");
 end else begin ce=1;rel=1;@(negedge clk);rel=0;if(loaded) $fatal(1,"release");end
 end
 // Reset pending state and require a new complete configuration/frame.
 ce=0;rst=0;@(negedge clk);if(mv||loaded||sr) $fatal(1,"reset");
 $display("PASS BRIEF {w}x{h} BITS={bits} DESC={length}:30 descriptors patterns/borders/snapshot/errors/CE/reset");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'brief_descriptor.sv',p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS BRIEF' in text;print(text.strip())
 return {'width':w,'height':h,'bits':bits,'descriptor_bits':length,'radius':radius,'descriptors':30,'result':'PASS'}
if __name__=='__main__':
 results=[run(*args) for args in ((9,7,8,128,2),(7,9,10,256,3),(1,1,12,128,0))]
 for parameter,value in [('WIDTH',0),('BITS',7),('DESC_BITS',64),('RADIUS',32)]:
  with tempfile.TemporaryDirectory(prefix='brief_invalid_') as td:
   p=Path(td)
   execute(['iverilog','-g2012','-s','brief_descriptor','-P',f'brief_descriptor.{parameter}={value}','-o',p/'sim',HERE/'brief_descriptor.sv'],p,p/'compile.log')
   try:execute(['vvp',p/'sim'],p,p/'run.log')
   except RuntimeError as exc:assert 'invalid BRIEF parameters' in str(exc)
   else:raise AssertionError('invalid parameter accepted')
   results.append({'invalid_parameter':parameter,'value':value,'result':'REJECTED'})
 for width,height,valid in ((256,256,True),(257,256,False),(65535,65535,False)):
  with tempfile.TemporaryDirectory(prefix='brief_geometry_') as td:
   p=Path(td)
   execute(['iverilog','-g2012','-s','brief_descriptor','-P',f'brief_descriptor.WIDTH={width}','-P',f'brief_descriptor.HEIGHT={height}','-o',p/'sim',HERE/'brief_descriptor.sv'],p,p/'compile.log')
   try:execute(['vvp',p/'sim'],p,p/'run.log')
   except RuntimeError as exc:assert not valid and 'invalid BRIEF parameters' in str(exc)
   else:assert valid
   results.append({'width':width,'height':height,'geometry_only':True,'result':'ACCEPTED' if valid else 'REJECTED'})
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
