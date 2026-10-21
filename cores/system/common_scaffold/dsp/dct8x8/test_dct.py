from pathlib import Path
import sys,tempfile,math,random,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
C=[[(1/math.sqrt(8) if k==0 else .5)*math.cos(math.pi*(2*n+1)*k/16) for n in range(8)] for k in range(8)]
Q=[[math.floor(x*16384+.5) for x in row] for row in C]
def transform(data,inverse=False,floating=False):
 matrix=C if floating else Q
 def term(k,n):return matrix[n][k] if inverse else matrix[k][n]
 def rnd(x):return x if floating else (x+8192)//16384
 middle=[[rnd(sum(data[r*8+n]*term(k,n) for n in range(8))) for k in range(8)] for r in range(8)]
 return [rnd(sum(middle[n][col]*term(k,n) for n in range(8))) for k in range(8) for col in range(8)]
def run(bits):
 r=random.Random(bits);lim=(1<<(bits-1))-1;amplitude=min(100,lim//8)
 vectors=[[0]*64,[amplitude]*64,[amplitude]+[0]*63,[amplitude if i%2 else -amplitude for i in range(64)],
 [r.randint(-amplitude,amplitude) for _ in range(64)],[lim]*64,[-lim-1]*64]
 blocks=[];maxerr=0;roundtrip=0
 for inv in (0,1):
  for data in vectors:
   fixed=transform(data,inv);floating=transform(data,inv,True)
   maxerr=max(maxerr,max(abs(a-b) for a,b in zip(fixed,floating)))
   expected=[min(lim,max(-lim-1,x)) for x in fixed]
   blocks.append((inv,data,expected,any(a!=b for a,b in zip(expected,fixed))))
 for data in vectors[:5]:
  coefficients=transform(data);recovered=transform(coefficients,True)
  roundtrip=max(roundtrip,max(abs(a-b) for a,b in zip(data,recovered)))
  assert all(-lim-1<=x<=lim for x in coefficients+recovered)
  blocks.append((1,coefficients,recovered,False))
 assert roundtrip<=3
 # Each Q14 coefficient has <=0.5 LSB error; propagate both separable
 # passes with row l1-norm <=sqrt(8), plus two rounding terms.
 assert maxerr<=math.ceil(16*(lim+1)*math.sqrt(8)/32768+3)
 with tempfile.TemporaryDirectory(prefix='dct8x8_') as td:
  p=Path(td)
  mask=(1<<bits)-1
  for name,values in [('in.mem',[v for _,d,_,_ in blocks for v in d]),('out.mem',[v for _,_,d,_ in blocks for v in d])]:
   (p/name).write_text('\n'.join(f'{v&mask:x}' for v in values))
  sats=sum(int(s)<<i for i,(_,_,_,s) in enumerate(blocks))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,cv=0,inv=0,sv=0,mr=0;
 reg signed [{bits-1}:0] sd;wire sr,mv,cr,cd,busy,sat;wire signed [{bits-1}:0] md;
 dct8x8_serial #(.BITS({bits})) dut(clk,rst,ce,cv,inv,cr,cd,sd,sv,sr,md,mv,mr,busy,sat);
 reg [{bits-1}:0] im[0:{len(blocks)*64-1}],om[0:{len(blocks)*64-1}];reg [{len(blocks)-1}:0] sats={len(blocks)}'d{sats};
 integer bi,ii,oo,ticks=0;reg [31:0] rng=123;reg stalled=0,take;reg [{bits-1}:0] held;
 always @(posedge clk) begin
 ticks=ticks+1;if(ticks>100000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||md!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held=md;end else stalled=0;
 end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);
 repeat(3) @(negedge clk);rst=1;
 // partial block flush
 sd=7;sv=1;@(negedge clk);sv=0;rst=0;@(negedge clk);rst=1;
 for(bi=0;bi<{len(blocks)};bi=bi+1) begin
 ce=1;cv=1;inv=bi>=7;@(negedge clk);if(!cd) $fatal(1,"config");cv=0;
 ii=0;oo=0;
 while(oo<64) begin
 if(ii<64) begin if(!sv) sv=rng[4]|rng[5];sd=im[bi*64+ii];end else sv=0;
 @(posedge clk);take=ce&&sv&&sr;if(take) ii=ii+1;
 if(ce&&mv&&mr) begin if(md!==om[bi*64+oo]) $fatal(1,"numeric block=%0d pixel=%0d",bi,oo);oo=oo+1;end
 tick;if(take) sv=0;
 end
 if(busy||sat!==sats[bi]) $fatal(1,"terminal saturation");sv=0;
 end
 $display("PASS DCT/IDCT bits={bits} {len(blocks)} blocks DC/impulse/random/fullscale/roundtrip/CE/stall/reset");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'dct8x8_serial.sv',p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS DCT' in text;print(text.strip())
 return {'bits':bits,'blocks':len(blocks),'outputs':len(blocks)*64,'max_unclipped_float_error':maxerr,'roundtrip_max_error':roundtrip,'result':'PASS'}
if __name__=='__main__':
 results=[run(b) for b in (8,12,16)]
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
