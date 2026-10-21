"""Independent spatial-coordinate oracle and randomized cycle simulation."""
from pathlib import Path
import json, random, subprocess, tempfile, math, os
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[4]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=str(OSS/'bin')+os.pathsep+str(OSS/'lib')+os.pathsep+os.environ['PATH']
def run(w,h,bits):
 r=random.Random(w*100+h+bits); maximum=(1<<bits)-1
 cw,ch=(w+1)//2,(h+1)//2
 frames=[]; expected=[]; beats=[]
 for mode in range(2):
  for hs in range(2):
   for vs in range(2):
    yy=[[r.randrange(maximum+1) for x in range(w)] for y in range(h)]
    cc=[[[r.randrange(maximum+1) for k in range(2)] for x in range(cw)] for y in range(ch)]
    for y in range(h):
     for x in range(cw):
      last=x==cw-1; cl=y%2 or y==h-1
      beats.append(((yy[y][2*x]<<bits)|yy[y][min(2*x+1,w-1)],int(y==0 and x==0),int(last and not cl)))
      if cl: beats.append(((1<<(2*bits))|(cc[y//2][x][0]<<bits)|cc[y//2][x][1],0,int(last)))
    for y in range(h):
     for x in range(w):
      u=(x-(0.5 if hs else 0))/2;v=(y-(0.5 if vs else 0))/2
      if mode==0: xx=[math.floor(u+0.5)]*2;zz=[math.floor(v+0.5)]*2;fx=fy=0
      else: xx=[math.floor(u),math.floor(u)+1];zz=[math.floor(v),math.floor(v)+1];fx=u-xx[0];fy=v-zz[0]
      vals=[]
      for k in range(2):
       taps=[[cc[min(ch-1,max(0,j))][min(cw-1,max(0,i))][k] for i in xx] for j in zz]
       f=(taps[0][0]*(1-fx)+taps[0][1]*fx)*(1-fy)+(taps[1][0]*(1-fx)+taps[1][1]*fx)*fy
       # Exact integer weights provide an independent rounding cross-check.
       wx,wy=round(4*fx),round(4*fy)
       integer=(taps[0][0]*(4-wx)*(4-wy)+taps[0][1]*wx*(4-wy)+taps[1][0]*(4-wx)*wy+taps[1][1]*wx*wy+8)//16
       assert integer==math.floor(f+0.5)
       vals.append(integer)
      expected.append(((yy[y][x]<<(2*bits))|(vals[0]<<bits)|vals[1],int(x==0 and y==0),int(x==w-1)))
    frames.append((mode,hs,vs))
 with tempfile.TemporaryDirectory(prefix='chroma420_') as td:
  p=Path(td)
  def mem(name,values): (p/name).write_text('\n'.join(f'{v:x}' for v in values)+'\n')
  mem('input.mem',[(d<<2)|(s<<1)|e for d,s,e in beats]);mem('expect.mem',[(d<<2)|(s<<1)|e for d,s,e in expected])
  n=len(beats)//8; m=w*h
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,cv=0,sv=0,su=0,sl=0,mr=0;
 reg [1:0] mode=0,hs=0,vs=0;reg [{2*bits}:0] sd;
 wire cr,cd,er,sr,mv,mu,ml,busy,me;wire [{3*bits-1}:0] md;
 chroma_420_to_444 #(.WIDTH({w}),.HEIGHT({h}),.BITS({bits})) dut(clk,rst_n,ce,cv,cr,mode,hs,vs,cd,er,sd,sv,su,sl,sr,md,mv,mu,ml,mr,busy,me);
 reg [{2*bits+2}:0] inputs[0:{len(beats)-1}];reg [{3*bits+1}:0] outputs[0:{len(expected)-1}];
 integer fi,ii,oo,cycles=0;reg took;reg [31:0] rng=32'h1234abcd;reg [{3*bits+1}:0] held;reg stalled=0;
 always @(posedge clk) begin
 cycles=cycles+1;if(cycles>200000) $fatal(1,"timeout");
 if(rst_n) begin
 if(stalled && {{md,mu,ml}}!==held) $fatal(1,"stall changed");
 stalled=mv && (!ce || !mr);held={{md,mu,ml}};
 end else stalled=0;
 end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 initial begin
 $readmemh("input.mem",inputs);$readmemh("expect.mem",outputs);
 repeat(3) @(negedge clk);rst_n=1;
 // Abort a partial frame and verify synchronous reset flushes state.
 sd=0;su=1;sl=0;sv=1;@(negedge clk);sv=0;rst_n=0;@(negedge clk);rst_n=1;
 for(fi=0;fi<8;fi=fi+1) begin
 ce=1;mode=fi/4;hs=(fi/2)%2;vs=fi%2;cv=1;
 @(negedge clk);if(!cd||er) $fatal(1,"config");cv=0;
 // Rejected config must retain all three active fields.
 mode=3;hs=3;vs=3;cv=1;@(negedge clk);if(!er||cd) $fatal(1,"invalid config");cv=0;
 ii=0;oo=0;
 while(oo<{m}) begin
 if(ii<{n}) begin if(!sv) sv=rng[4]|rng[5];{{sd,su,sl}}=inputs[fi*{n}+ii];end else sv=0;
 @(posedge clk);
 took=ce && sv && sr;if(took) ii=ii+1;
 if(ce && mv && mr) begin if({{md,mu,ml}}!==outputs[fi*{m}+oo]) $fatal(1,"pixel fi=%0d idx=%0d got=%h expect=%h",fi,oo,{{md,mu,ml}},outputs[fi*{m}+oo]);oo=oo+1;end
 tick;if(took) sv=0;
 end
 sv=0;if(busy||me) $fatal(1,"terminal");
 end
 // Marker errors are sticky, independently of capture geometry.
 ce=1;sd=0;sv=1;su=0;sl=0;@(negedge clk);sv=0;if(!me) $fatal(1,"marker error missing");
 $display("PASS {w}x{h} BITS={bits} eight modes/reset/stall/config/marker");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  subprocess.run(['iverilog','-g2012','-s','tb','-o',str(p/'sim'),str(ROOT/'chroma_420_to_444.sv'),str(p/'tb.sv')],check=True)
  out=subprocess.run(['vvp',str(p/'sim')],cwd=p,check=True,capture_output=True,text=True).stdout
  print(out.strip());return {'width':w,'height':h,'bits':bits,'frames':8,'outputs':len(expected),'result':'PASS'}
if __name__=='__main__':
 results=[run(w,h,b) for b in (8,10) for w,h in ((1,1),(1,2),(2,1),(2,2),(3,5),(6,4),(5,2),(2,5))]
 for parameter,value in [('BITS',9),('WIDTH',0),('HEIGHT',0)]:
  with tempfile.TemporaryDirectory(prefix='chroma420_invalid_') as td:
   binary=Path(td)/'sim'
   subprocess.run(['iverilog','-g2012','-s','chroma_420_to_444','-P',f'chroma_420_to_444.{parameter}={value}','-o',str(binary),str(ROOT/'chroma_420_to_444.sv')],check=True,capture_output=True)
   out=subprocess.run(['vvp',str(binary)],capture_output=True,text=True)
   assert out.returncode!=0 and 'invalid geometry/BITS' in out.stdout
   results.append({'invalid_parameter':parameter,'value':value,'result':'REJECTED'})
 (ROOT/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
