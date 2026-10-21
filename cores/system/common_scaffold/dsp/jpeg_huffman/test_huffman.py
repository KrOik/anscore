from pathlib import Path
import sys,tempfile,random,json
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE));sys.path.insert(0,str(HERE.parents[1]))
from tables import TABLES
from integration.tooling import execute
def oracle(t):
 # Direct first-code formula, independent of the iterative RTL-table generator.
 result={};offset=0
 for length,n in enumerate(t['counts'],1):
  first=sum(t['counts'][j-1]*(1<<(length-j)) for j in range(1,length))
  for rank in range(n):result[t['values'][offset+rank]]=(first+rank,length)
  offset+=n
 return result
def packet(dc,run,size,amp,end,restart,component):
 return ((((((dc<<4)|run)<<4|size)<<16|amp)<<1|end)<<1|restart)<<2|component
def expected(code,bits,amp,size,end,restart,component):
 return ((((((code<<5)|bits)<<16|amp)<<5|size)<<1|end)<<1|restart)<<2|component
r=random.Random(638);inputs=[];outputs=[]
for component in (0,1,2):
 for dc in (True,False):
  name=('dc_' if dc else 'ac_')+('luminance' if component==0 else 'chrominance')
  for symbol,(code,bits) in oracle(TABLES[name]).items():
   size=symbol if dc else symbol&15;run=0 if dc else symbol>>4
   amp=r.randrange(1<<size);end=r.randrange(2);restart=r.randrange(2) if dc else 0
   inputs.append(packet(dc,run,size,amp,end,restart,component));outputs.append(expected(code,bits,amp,size,end,restart,component))
bad=[(packet(1,0,0,0,0,0,3),1),(packet(1,0,12,0,0,0,0),2),
 (packet(1,1,2,0,0,0,0),2),(packet(0,5,0,0,0,0,0),2),
 (packet(0,0,11,0,0,0,0),2),(packet(1,0,0,1,0,0,0),3),
 (packet(0,0,1,2,0,0,0),3),(packet(0,0,1,1,0,1,0),4)]
with tempfile.TemporaryDirectory(prefix='jpeg_huffman_') as td:
 p=Path(td)
 for name,values in [('in.mem',inputs),('out.mem',outputs),('bad.mem',[x for x,_ in bad]),('errors.mem',[e for _,e in bad])]:
  (p/name).write_text('\n'.join(f'{v:x}' for v in values))
 tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,sv=0,mr=0;reg [28:0] sd;
 wire sr,mv;wire [15:0] code,amp;wire [4:0] cb,ab;wire be,re;wire [1:0] component;wire [3:0] error;
 jpeg_default_huffman dut(clk,rst,ce,sv,sr,sd[28],sd[27:24],sd[23:20],sd[19:4],sd[3],sd[2],sd[1:0],mv,mr,code,cb,amp,ab,be,re,component,error);
 wire [45:0] payload={{code,cb,amp,ab,be,re,component}};
 reg [28:0] im[0:{len(inputs)-1}],bad[0:7];reg [45:0] om[0:{len(outputs)-1}];reg [3:0] errors[0:7];
 integer ii=0,oo=0,k,ticks=0;reg [31:0] rng=919;reg stalled=0,take;reg [45:0] held;
 always @(posedge clk) begin ticks=ticks+1;if(ticks>10000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||payload!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held=payload;end else stalled=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);$readmemh("bad.mem",bad);$readmemh("errors.mem",errors);
 repeat(3) @(negedge clk);rst=1;
 while(oo<{len(outputs)}) begin
 if(ii<{len(inputs)}) begin if(!sv) sv=rng[4]|rng[5];sd=im[ii];end else sv=0;
 @(posedge clk);take=ce&&sv&&sr;if(take) ii=ii+1;
 if(ce&&mv&&mr) begin if(payload!==om[oo]) $fatal(1,"code %0d got %h exp %h",oo,payload,om[oo]);oo=oo+1;end
 tick;if(take) sv=0;
 end
 if(error) $fatal(1,"legal token error");sv=0;
 for(k=0;k<8;k=k+1) begin
 rst=0;ce=1;mr=1;@(negedge clk);rst=1;sd=bad[k];sv=1;@(negedge clk);sv=0;
 if(error!==errors[k]||sr||mv) $fatal(1,"error category %0d",k);
 repeat(3) @(negedge clk);if(error!==errors[k]||sr) $fatal(1,"failstop");
 end
 // Reset must discard a pending stalled result even with CE disabled.
 rst=0;@(negedge clk);rst=1;sv=1;sd=im[0];mr=0;@(negedge clk);sv=0;ce=0;
 if(!mv) $fatal(1,"pending test");rst=0;@(negedge clk);if(mv||error) $fatal(1,"reset");
 $display("PASS default Huffman {len(outputs)} canonical codes/component mappings + 8 invalid/reset/CE/stall");$finish;
 end endmodule'''
 (p/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'jpeg_default_huffman.sv',p/'tb.sv'],p,p/'compile.log')
 text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS default' in text;print(text.strip())
 (HERE/'evidence.json').write_text(json.dumps({'result':'PASS','unique_default_codes':348,'token_mappings':len(inputs),'invalid_tokens':len(bad),'independent_oracle':'direct first-code sum versus iterative ROM generator'},indent=2)+'\n')
