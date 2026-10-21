"""Contrast AF independent search/curve reference plus actuator-latency RTL loop."""
from pathlib import Path
import os,tempfile,subprocess,json,random
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def scan_positions(lo,hi,step):
    return sorted(set(list(range(lo,hi+1,step))+[hi]))
def oracle(table,lo,hi,coarse,fine):
    def winner(ps):return max(ps,key=lambda p:(sum(table[p]),-p))
    a=scan_positions(lo,hi,coarse);peak=winner(a)
    b=scan_positions(max(lo,peak-coarse),min(hi,peak+coarse),fine);best=winner(b+[peak])
    return a+b+[best],best,sum(table[best])
def run():
 rng=random.Random(20261019);cases=[]
 curves={
 'parabolic':lambda p:max(0,2000-7*(p-31)**2),
 'flat':lambda p:777,
 'double_peak':lambda p:max(1500-30*abs(p-12),2100-40*abs(p-44),0),
 'left_boundary':lambda p:3000-30*p,
 'right_boundary':lambda p:100+30*p,
 'noisy':lambda p:max(0,3000-9*(p-23)**2),
 'sharp_coarse_peak':lambda p:4000 if p==10 else 100,
 }
 with tempfile.TemporaryDirectory(prefix='af_controller_') as temp:
  td=Path(temp)
  for name,curve in list(curves.items())+[('singleton',lambda p:900),('unaligned_bounds',lambda p:max(0,3000-9*(p-37)**2))]:
   table=[[max(0,curve(p)+(rng.randrange(-15,16) if name=='noisy' else 0)) for k in range(3)] for p in range(64)]
   lo,hi,coarse,fine=(10,10,10,2) if name=='singleton' else (5,58,13,3) if name=='unaligned_bounds' else (0,20,10,6) if name=='sharp_coarse_peak' else (0,63,10,2)
   commands,best,score=oracle(table,lo,hi,coarse,fine)
   (td/'metrics.hex').write_text('\n'.join(f'{v:x}' for row in table for v in row))
   (td/'commands.hex').write_text('\n'.join(f'{p:x}' for p in commands))
   tb=TB.replace('@LO@',str(lo)).replace('@HI@',str(hi)).replace('@CS@',str(coarse)).replace('@FS@',str(fine)).replace('@NC@',str(len(commands))).replace('@BEST@',str(best)).replace('@SCORE@',str(score))
   (td/'tb.sv').write_text(tb)
   subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'contrast_af_controller.v'),str(td/'tb.sv')],check=True,capture_output=True)
   p=subprocess.run(['vvp',str(td/'sim')],cwd=td,text=True,capture_output=True)
   if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(name+'\n'+p.stdout+p.stderr)
   print(name,p.stdout.splitlines()[0]);cases.append({'curve':name,'commands':len(commands),'position':best,'score':score})
  # Static parameter guard is tested independently.
  for name,value in (('POS_W',1),('METRIC_W',33)):
   (td/'bad.sv').write_text(f'module tb;contrast_af_controller #(.{name}({value})) d();endmodule')
   subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'bad'),str(ROOT/'contrast_af_controller.v'),str(td/'bad.sv')],check=True,capture_output=True)
   assert subprocess.run(['vvp',str(td/'bad')],capture_output=True).returncode
 (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','curves':cases,'invalid_static_parameters':2,'error_tests':['invalid config','lens failure','ack position mismatch','metric bounds','abort','timeout'],'seed':20261019},indent=2)+'\n')
TB=r'''
module tb;
localparam NC=@NC@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,start=0,abort=0,ar=0,av=0,ae=0,mv=0,rr=0;
reg[5:0] amin=@LO@,amax=@HI@,cs=@CS@,fs=@FS@,ackpos=0;
reg[7:0] settle=2,samples=3;reg[15:0] minmetric=0,maxmetric=65535,metric=0;
reg[31:0] timeout=10000;
wire ready,actv,ackr,mr,rv,busy;wire[5:0] actpos,resultpos;wire[23:0] score;wire[7:0] rs;wire[3:0] err;wire[31:0] measured,dropped;
contrast_af_controller #(.POS_W(6),.METRIC_W(16)) d(clk,rst,ce,start,ready,abort,amin,amax,cs,fs,settle,samples,minmetric,maxmetric,timeout,actv,ar,actpos,av,ackr,ackpos,ae,mv,mr,metric,rv,rr,resultpos,score,rs,err,busy,measured,dropped);
reg[15:0] values[0:191];reg[5:0] commands[0:NC-1];
reg[31:0] random_state=32'hc6a821;integer cycles=0,cmdcount=0,delay_left=-1,target=0,actual=0,oldpos=0,age=0,sampleindex=0;
integer mode=0;reg checking=1;reg actheld=0,resultheld=0;reg[5:0] acthold;reg[41:0] reshold;
always @(negedge clk) begin
 random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
 ce=random_state[0]|random_state[2];ar=(mode!=6)&&(random_state[1]|random_state[4]);
 mv=(mode!=6)&&(random_state[3]|random_state[5]);
 av=(delay_left==0)&&(mode!=6);ae=mode==2;ackpos=(mode==3)?target^1:target;
 if(mode==4) metric=65535;
 else if(age<2) metric=values[oldpos*3];
 else metric=values[actual*3+(sampleindex%3)];
end
always @(posedge clk) if(!rst) begin
 cycles=cycles+1;if(cycles>50000)$fatal(1,"watchdog");
 if(actheld&&(!actv||actpos!==acthold)&&!abort&&!rv)$fatal(1,"actuator stability mode%0d state%0d err%0d",mode,d.state,err);
 actheld=actv&&!(ce&&ar);acthold=actpos;
 if(resultheld&&(!rv||{resultpos,score,rs,err}!==reshold))$fatal(1,"result stability");
 resultheld=rv&&!(ce&&rr);reshold={resultpos,score,rs,err};
 if(ce) begin
 if(actv&&ar) begin
 if(checking&&(cmdcount>=NC||actpos!==commands[cmdcount]))$fatal(1,"command %0d got %0d expected %0d",cmdcount,actpos,commands[cmdcount]);
 target=actpos;delay_left=4;cmdcount=cmdcount+1;
 end else if(delay_left>0) delay_left=delay_left-1;
 if(av&&ackr) begin delay_left=-1;oldpos=actual;actual=target;age=0;sampleindex=0;end
 else if(mv&&mr&&delay_left==-1) begin if(age>=2)sampleindex=sampleindex+1;age=age+1;end
 end
end
 task go;begin
 @(negedge clk);#1;start=1;@(posedge clk);while(!ready)@(posedge clk);
 @(negedge clk);#1;start=0;
 end endtask
 task wait_result(input integer expected_error);begin
 while(!rv)@(negedge clk);#1;
 if(err!=expected_error)$fatal(1,"error code got %0d expected %0d",err,expected_error);
 repeat(8)@(negedge clk);
 #1;rr=1;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;rr=0;delay_left=-1;actheld=0;resultheld=0;
 end endtask
 initial begin
 $readmemh("metrics.hex",values);$readmemh("commands.hex",commands);
 repeat(3)@(negedge clk);#1;rst=0;
 go;
 // A busy start/config mutation cannot replace the latched search.
 cs=0;fs=0;start=1;repeat(3)@(negedge clk);#1;start=0;
 while(!rv)@(negedge clk);#1;
 if(err||resultpos!=@BEST@||score!=@SCORE@||rs!=3||cmdcount!=NC||measured!=NC-1||actual!=resultpos)$fatal(1,"closed loop result pos%0d score%0d commands%0d",resultpos,score,cmdcount);
 wait_result(0);checking=0;cs=@CS@;fs=@FS@;
 cs=0;go;wait_result(1);cs=@CS@;
 amin=20;amax=10;go;wait_result(1);amin=@LO@;amax=@HI@;
 fs=0;go;wait_result(1);fs=@FS@;
 samples=0;go;wait_result(1);samples=3;
 minmetric=10;maxmetric=9;go;wait_result(1);minmetric=0;maxmetric=65535;
 mode=2;go;wait_result(2);
 mode=3;go;wait_result(3);
 mode=4;maxmetric=100;go;wait_result(4);maxmetric=65535;
 mode=0;go;@(negedge clk);#1;abort=1;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;abort=0;wait_result(5);
 mode=6;timeout=8;go;wait_result(6);
 // Reset a live request independently of CE; no result is retained.
 timeout=10000;go;@(negedge clk);#1;rst=1;@(negedge clk);#1;rst=0;
 if(busy||actv||rv)$fatal(1,"reset");
 $display("PASS autofocus closed-loop + six terminal errors");$finish;
 end
endmodule
'''
if __name__=='__main__':run()
