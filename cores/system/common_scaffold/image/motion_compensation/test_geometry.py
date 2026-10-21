from pathlib import Path
import sys,tempfile,json,importlib.util
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
spec=importlib.util.spec_from_file_location('motion_compensation_geometry_helpers',HERE/'run_tests.py')
helpers=importlib.util.module_from_spec(spec);spec.loader.exec_module(helpers)

def main():
 results=[]
 for w,h,bw,bh,output in ((65535,1,64,1,True),(256,256,64,64,False)):
  tb=helpers.HEADER.replace('module tb;',f'module tb;localparam W={w},H={h},B=8,BW={bw},BH={bh};')
  tb=tb[:tb.index('integer t,tx,ty;')]
  tb+=r'''
integer t,tx,ty,xx;reg signed [15:0] shift;
initial begin @(negedge clk);tick;rst_n=1;tick;
for(t=0;t<2;t=t+1)begin
 shift=t==0?16'sd32767:-16'sd32768;
 // First reference and first vector can load on the same edge.
 sp=0;sof=1;eol=W==1;sv=1;vx=0;vy=0;vw=BW;vh=BH;dx=shift;dy=0;vi=0;vv=1;tick;sv=0;vv=0;
 if(rc!=1||vc!=1)$fatal(1,"parallel load");
 for(ty=0;ty<H;ty=ty+1)for(tx=0;tx<W;tx=tx+1)if(tx!=0||ty!=0)pixel(tx,0,tx==W-1);
 for(ty=0;ty<H;ty=ty+BH)for(tx=0;tx<W;tx=tx+BW)if(tx!=0||ty!=0)vector(tx,ty,W-tx<BW?W-tx:BW,H-ty<BH?H-ty:BH,shift,0,0);
 if(rc!=W*H||vc!=((W+BW-1)/BW)*((H+BH-1)/BH))$fatal(1,"capacity counter");
 launch(241);
'''
  if output:
   tb+=r'''
 for(tx=0;tx<W;tx=tx+1)begin
  xx=tx+$signed(shift);
  while(!mv)tick;
  if(mx!=tx||my!=0||mp!==(xx<0||xx>=W?8'd241:xx[7:0])||reason!==(xx<0||xx>=W?2'd2:2'd0)||inv!==(xx<0||xx>=W))$fatal(1,"wide coordinate");
  mr=1;tick;mr=0;
 end
 release_frame;
'''
  else:tb+='tick;rst_n=0;tick;rst_n=1;tick;\n'
  tb+='end $display("PASS geometry");$finish;end endmodule\n'
  tag=f'{w}x{h}'
  with tempfile.TemporaryDirectory(prefix='motion_comp_geometry_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim.vvp',HERE/'motion_compensation.sv',p/'tb.sv'],p,HERE/f'geometry_compile_{tag}.log')
   out=execute(['vvp',p/'sim.vvp'],p,HERE/f'geometry_{tag}.log',timeout=120);assert 'PASS geometry' in out
  results.append({'geometry':tag,'frames':2,'output_pixels':w*h*2 if output else 0,'status':'PASS'})
 (HERE/'geometry_evidence.json').write_text(json.dumps(results,indent=2)+'\n');print(results)
if __name__=='__main__':main()
