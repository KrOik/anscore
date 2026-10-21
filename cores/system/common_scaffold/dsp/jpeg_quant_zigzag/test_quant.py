from pathlib import Path
import sys,tempfile,random,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
# Independent literal JPEG scan order, compared against diagonal-generated RTL.
Z=[0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]
assert sorted(Z)==list(range(64))
def model(data,table,inverse,bits):
 lim=(1<<(bits-1))-1
 if inverse:
  raster=[0]*64
  for i,idx in enumerate(Z):raster[idx]=data[i]
  result=[x*q for x,q in zip(raster,table)]
 else:
  raster=[(-1 if x<0 else 1)*((abs(x)+q//2)//q) for x,q in zip(data,table)]
  result=[raster[i] for i in Z]
 return [min(lim,max(-lim-1,x)) for x in result],any(x>lim or x< -lim-1 for x in result)
def run(bits):
 r=random.Random(bits);lim=(1<<(bits-1))-1;blocks=[]
 for inv in (0,1):
  for kind in range(5):
   table=[1]*64 if kind==0 else [r.randrange(1,256) for _ in range(64)]
   data=list(range(64)) if kind==0 else [r.randint(-lim-1,lim) for _ in range(64)]
   if kind==2:data=[-lim-1 if i%2 else lim for i in range(64)]
   if kind==3:data=[(-1 if i%2 else 1)*(table[i]//2) for i in range(64)]
   data=[min(lim,max(-lim-1,x)) for x in data]
   expected,sat=model(data,table,inv,bits);blocks.append((inv,data,table,expected,sat))
 with tempfile.TemporaryDirectory(prefix='jpeg_quant_') as td:
  p=Path(td);mask=(1<<bits)-1
  for name,values in [('in.mem',[x for _,d,_,_,_ in blocks for x in d]),('table.mem',[x for _,_,t,_,_ in blocks for x in t]),('out.mem',[x for _,_,_,d,_ in blocks for x in d])]:
   (p/name).write_text('\n'.join(f'{x&mask:x}' for x in values))
  satbits=sum(int(s)<<i for i,(_,_,_,_,s) in enumerate(blocks))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,tv=0,cv=0,inv=0,sv=0,mr=0;reg [5:0] ti;reg [7:0] tq;reg signed [{bits-1}:0] sd;
 wire tr,cr,cd,er,sr,mv,busy,sat;wire signed [{bits-1}:0] md;
 jpeg_quant_zigzag #(.BITS({bits})) dut(clk,rst,ce,tv,tr,ti,tq,cv,inv,cr,cd,er,sd,sv,sr,md,mv,mr,busy,sat);
 reg [{bits-1}:0] im[0:639],om[0:639];reg [7:0] tables[0:639];reg [9:0] sats=10'd{satbits};
 integer bi,i,ii,oo,ticks=0;reg [31:0] rng=77;reg stalled=0,take;reg [{bits-1}:0] held;
 always @(posedge clk) begin ticks=ticks+1;if(ticks>100000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||md!==held)) $fatal(1,"stall");stalled=mv&&(!ce||!mr);held=md;end else stalled=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 task commit;input bad;begin
 ce=1;cv=1;@(negedge clk);cv=0;
 while(!cd&&!er) @(negedge clk);
 if(bad ? (!er||cd):(!cd||er)) $fatal(1,"commit status");
 @(negedge clk);
 end endtask
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);$readmemh("table.mem",tables);
 repeat(3) @(negedge clk);rst=1;commit(1);if(sr) $fatal(1,"unconfigured input");
 for(bi=0;bi<10;bi=bi+1) begin
 ce=1;inv=bi>=5;
 for(i=0;i<64;i=i+1) begin tv=1;ti=i;tq=tables[bi*64+i];@(negedge clk);if(!tr) $fatal(1,"write");end tv=0;
 commit(0);
 // Reject a zero table with opposite mode and prove active table/mode retained.
 tv=1;ti=17;tq=0;@(negedge clk);tv=0;inv=!(bi>=5);commit(1);
 tv=1;ti=17;tq=tables[bi*64+17];@(negedge clk);tv=0;
 ii=0;oo=0;
 while(oo<64) begin
 if(ii<64) begin if(!sv) sv=rng[4]|rng[5];sd=im[bi*64+ii];end else sv=0;
 @(posedge clk);take=ce&&sv&&sr;if(take) ii=ii+1;
 if(ce&&mv&&mr) begin if(md!==om[bi*64+oo]) $fatal(1,"numeric b=%0d i=%0d got=%0d exp=%0d",bi,oo,md,$signed(om[bi*64+oo]));oo=oo+1;end
 tick;if(take) sv=0;
 end
 sv=0;if(busy||sat!==sats[bi]) $fatal(1,"terminal");
 end
 ce=1;sv=1;sd=1;@(negedge clk);sv=0;rst=0;@(negedge clk);rst=1;
 if(mv||busy||sr) $fatal(1,"reset flush");
 $display("PASS JPEG quant/zigzag BITS={bits}:10blocks all-index random extremes ties config/zero/CE/reset");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'jpeg_quant_zigzag.sv',p/'tb.sv'],p,p/'compile.log')
  out=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS JPEG' in out;print(out.strip())
 return {'bits':bits,'blocks':10,'outputs':640,'result':'PASS'}
if __name__=='__main__':
 results=[run(b) for b in (8,12,16)]
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
