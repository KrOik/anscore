from pathlib import Path
import sys,tempfile,random,json
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def run(w,h,bits,window):
 n=w*h;maximum=(1<<bits)-1;r=random.Random(n*83+window)
 batches=[]
 for epoch in range(3):
  frames=[[100]*n for _ in range(window)]
  for value in (110,111,0,maximum):
   a=[100]*n;a[(epoch+value)%n]=value;frames.append(a)
  frames += [[r.randrange(maximum+1) for _ in range(n)] for _ in range(2)]
  batches.append(frames)
 inputs=[];expected=[];frame_start=[];thresholds=[]
 for batch in batches:
  history=[]
  for frame_index,image in enumerate(batch):
   threshold=10 if frame_index<window+4 else (maximum if frame_index==window+4 else 0)
   thresholds.append(threshold)
   frame_start.append(len(inputs))
   for i,pixel in enumerate(image):
    warm=len(history)<window
    median=0 if warm else sorted(frame[i] for frame in history)[window//2]
    foreground=not warm and abs(pixel-median)>threshold
    inputs.append(pixel)
    expected.append((median<<4)|(int(foreground)<<3)|(int(warm)<<2)|(int(i==0)<<1)|int(i%w==w-1))
   history.append(image)
   history=history[-window:]
 frames_per_batch=len(batches[0]);total=len(frame_start)
 with tempfile.TemporaryDirectory(prefix='median_background_') as td:
  p=Path(td)
  for name,values in [('in.mem',inputs),('out.mem',expected),('threshold.mem',thresholds)]: (p/name).write_text('\n'.join(f'{v:x}' for v in values))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,cv=0,sv=0,sof=0,eol=0,mr=0;reg [{bits-1}:0] sd,threshold;
 wire cr,cd,sr,mv,ms,me,fg,warm,busy,done;wire [{bits-1}:0] bg;wire [3:0] error;
 temporal_median_background #(.WIDTH({w}),.HEIGHT({h}),.BITS({bits}),.WINDOW({window})) dut(clk,rst,ce,cv,cr,threshold,cd,sd,sv,sof,eol,sr,bg,fg,warm,mv,ms,me,mr,busy,done,error);
 wire [{bits+3}:0] payload={{bg,fg,warm,ms,me}};
 reg [{bits-1}:0] im[0:{len(inputs)-1}],thresholds[0:{total-1}];reg [{bits+3}:0] om[0:{len(expected)-1}],held;
 integer frame,ii,oo,ticks=0;reg [31:0] rng=71;reg stalled=0,take;
 always @(posedge clk) begin ticks=ticks+1;if(ticks>200000) $fatal(1,"timeout");
 if(rst) begin if(stalled&&(!mv||payload!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held=payload;end else stalled=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 task abortframe;begin
 ce=1;mr=1;
 if({n}>1) begin
 sv=1;sd=77;sof=1;eol={int(w==1)};@(negedge clk);sv=0;
 while(!mv) @(negedge clk);@(negedge clk);
 end
 sv=1;sd=99;sof={int(n>1)};eol=0;@(negedge clk);sv=0;
 if(error!=1||!done||busy||mv) $fatal(1,"badframe invalidate");end endtask
 task resetframe;begin
 ce=1;mr=0;sv=1;sd=66;sof=1;eol={int(w==1)};@(negedge clk);sv=0;
 // Let COMPUTE overwrite one ring cell before reset while output is stalled.
 while(!mv) @(negedge clk);
 ce=0;rst=0;@(negedge clk);if(mv||busy||error) $fatal(1,"reset invalidate");rst=1;ce=1;mr=1;
 end endtask
 initial begin
 $readmemh("in.mem",im);$readmemh("out.mem",om);$readmemh("threshold.mem",thresholds);repeat(3) @(negedge clk);rst=1;
 for(frame=0;frame<{total};frame=frame+1) begin
 if(frame=={frames_per_batch}) abortframe;
 if(frame=={2*frames_per_batch}) resetframe;
 ce=1;cv=1;threshold=thresholds[frame];@(negedge clk);if(!cd) $fatal(1,"config");cv=0;ii=0;oo=0;
 while(oo<{n}) begin
 if(ii<{n}) begin if(!sv) sv=rng[4]|rng[5];sd=im[frame*{n}+ii];sof=ii==0;eol=ii%{w}=={w-1};end else sv=0;
 @(posedge clk);take=ce&&sv&&sr;if(take) ii=ii+1;
 if(ce&&mv&&mr) begin if(payload!==om[frame*{n}+oo]) $fatal(1,"numeric f=%0d i=%0d got=%h exp=%h",frame,oo,payload,om[frame*{n}+oo]);oo=oo+1;end
 tick;if(take) sv=0;
 end
 sv=0;if(error||busy||!done) $fatal(1,"terminal");
 end
 $display("PASS median background {w}x{h} BITS={bits} WINDOW={window} {total}frames old-only/threshold/fault/reset");$finish;
 end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'temporal_median_background.sv',p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS median' in text;print(text.strip())
 return {'width':w,'height':h,'bits':bits,'window':window,'frames':total,'outputs':len(expected),'result':'PASS'}
if __name__=='__main__':
 results=[run(w,h,b,k) for w,h,b,k in ((1,1,8,3),(1,5,10,5),(5,1,8,3),(3,5,12,5),(8,6,16,3))]
 for parameter,value in [('WIDTH',0),('HEIGHT',0),('BITS',7),('BITS',17),('WINDOW',4)]:
  with tempfile.TemporaryDirectory(prefix='median_bg_invalid_') as td:
   p=Path(td)
   execute(['iverilog','-g2012','-s','temporal_median_background','-P',f'temporal_median_background.{parameter}={value}','-o',p/'sim',HERE/'temporal_median_background.sv'],p,p/'compile.log')
   try:execute(['vvp',p/'sim'],p,p/'run.log')
   except RuntimeError as exc:assert 'invalid median background parameters' in str(exc)
   else:raise AssertionError('invalid parameter accepted')
   results.append({'invalid_parameter':parameter,'value':value,'result':'REJECTED'})
 (HERE/'evidence.json').write_text(json.dumps(results,indent=2)+'\n')
