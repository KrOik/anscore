from pathlib import Path
import sys,tempfile,json,random,math
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def run(bits,frac,ic_half=3,oc_half=5):
 r=random.Random(820+bits); n=180; count=60; scale=1<<frac
 samples=[r.randrange(-(1<<(bits-1)),1<<(bits-1)) for i in range(n)]
 samples[:6]=[-(1<<(bits-1)),(1<<(bits-1))-1,0,-1,1,0]
 steps=[scale//2,scale*7//4];pos=0;outputs=[]
 for i in range(count):
  lo=pos//scale;f=pos%scale
  integer=samples[lo]+((samples[lo+1]-samples[lo])*f+scale//2)//scale
  floating=samples[lo]*(1-f/scale)+samples[lo+1]*(f/scale)
  assert integer==math.floor(floating+0.5)
  outputs.append(integer);pos+=steps[0] if i<20 else steps[1]
 with tempfile.TemporaryDirectory(prefix='asrc_test_') as td:
  p=Path(td)
  (p/'in.mem').write_text('\n'.join(f'{v&((1<<bits)-1):x}' for v in samples))
  (p/'out.mem').write_text('\n'.join(f'{v&((1<<bits)-1):x}' for v in outputs))
  tb=f'''module tb;
 reg ic=0,oc=0,rst=0;always #{ic_half} ic=~ic;always #{oc_half} oc=~oc;
 reg signed [{bits-1}:0] sd;reg sv=0,mr=0,cv=0;reg [{frac+2}:0] step={steps[0]};
 wire sr,mv,cr,cd,ce,ov,uf;wire signed [{bits-1}:0] md;
 asrc_linear #(.BITS({bits}),.FRAC({frac}),.FIFO_ADDR(3)) dut(rst,ic,oc,sd,sv,sr,md,mv,mr,cv,cr,step,cd,ce,ov,uf);
 reg [{bits-1}:0] im[0:{n-1}],om[0:{count-1}];
 integer ii=0,oo=0,epoch=0,ticks=0;reg [31:0] ir=99,rr=16;reg stalled=0;reg [{bits-1}:0] held;
 reg change=0,changed=0;reg input_take;
 always @(posedge ic) begin input_take=rst&&sv&&sr;if(input_take) ii=ii+1;end
 always @(negedge ic) begin
 ir=ir^(ir<<13);ir=ir^(ir>>17);ir=ir^(ir<<5);
 if(!rst) begin sv=0;ii=0;end
 else if(ii<{n}) begin if(!sv||input_take) begin sd=im[ii];sv=ir[0]|ir[1];end end else sv=0;
 end
 always @(posedge oc) begin
 ticks=ticks+1;if(ticks>20000) $fatal(1,"timeout");
 if(!rst) begin oo=0;stalled=0;change=0;changed=0;end
 else begin
 if(stalled && (!mv || md!==held)) $fatal(1,"stall stability");
 stalled=mv&&!mr;held=md;
 if(mv&&mr) begin
 if(md!==om[oo]) $fatal(1,"numeric %0d got %0d expected %0d",oo,md,$signed(om[oo]));
 oo=oo+1;if(oo==20) change=1;
 end
 end end
 always @(negedge oc) begin
 rr=rr^(rr<<13);rr=rr^(rr>>17);rr=rr^(rr<<5);
 if(ticks>70) mr=rr[0]|rr[1];else mr=0;
 if(change&&!changed&&cr) begin cv=1;step={steps[1]};changed=1;end
 else if(changed) cv=0;
 end
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);
 repeat(4) @(negedge oc);rst=1;
 wait(cr);@(negedge oc);cv=1;step=0;
 @(negedge oc);if(!ce||cd) $fatal(1,"zero ratio not rejected");cv=1;step={steps[0]};
 @(negedge oc);if(!cd||ce) $fatal(1,"ratio commit");cv=0;
 wait(oo=={count});@(negedge oc);
 if(!ov||!uf) $fatal(1,"status coverage missing");
 // Common reset flushes a nonempty FIFO and a possibly pending output.
 rst=0;@(negedge oc);if(mv||ov||uf) $fatal(1,"flush reset");
 $display("PASS async ASRC BITS={bits} FRAC={frac}: numeric dynamic-ratio stalls overflow underflow reset");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'asrc_linear.sv',p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'sim.log');assert 'PASS async' in text;print(text.strip())
  return {'bits':bits,'frac':frac,'input_clock_half':ic_half,'output_clock_half':oc_half,'outputs':count,'result':'PASS'}
if __name__=='__main__':
 results=[run(b,f) for b,f in ((8,4),(16,12),(24,16))]+[run(16,8,7,2)]
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
