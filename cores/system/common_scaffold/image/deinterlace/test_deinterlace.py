from pathlib import Path
import sys,tempfile,json,random,hashlib
import numpy as np
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
rng=random.Random(92071)
stats={'frames':0,'pixels':0,'bob_pixels':0,'mode_differences':0}
def oracle(older,newer,first,mode,threshold):
 h,w=older.shape
 if h==1:return [(int(older[0,x]),0) for x in range(w)]
 ref=1-first;out=[]
 for y in range(h):
  for x in range(w):
   source=int(older[y,x]) if y%2==first else int(newer[y,x])
   use=0
   if y%2!=ref and mode!=0:
    up=y-1 if y>0 else 1;dn=y+1 if y<h-1 else y-1
    bob=(int(newer[up,x])+int(newer[dn,x])+1)//2
    use=int(mode==1 or abs(source-bob)>threshold)
    if use:source=bob
   out.append((source,use))
 return out
def run(w,h,bits):
 mx=(1<<bits)-1;yy,xx=np.indices((h,w));fixtures=[]
 patterns=[]
 patterns.append((np.zeros((h,w),dtype=int),np.zeros((h,w),dtype=int),'zero'))
 patterns.append((np.full((h,w),mx),np.full((h,w),mx),'max'))
 static=np.minimum(mx,xx*2+yy*4)
 patterns.append((static,static.copy(),'static_linear'))
 patterns.append((np.zeros((h,w),dtype=int),np.full((h,w),mx),'temporal_comb'))
 older=np.where((xx>=w//3)&(xx<w//3+max(1,w//3)),mx,0)
 newer=np.where((xx>=w//2)&(xx<w//2+max(1,w//3)),mx,0)
 patterns.append((older,newer,'moving_bar'))
 for _ in range(3):patterns.append((np.array([[rng.randrange(mx+1) for x in range(w)] for y in range(h)]),np.array([[rng.randrange(mx+1) for x in range(w)] for y in range(h)]),'random'))
 for first in (0,1):
  for a,b,label in patterns:
   outputs=[]
   for mode in (0,1,2):
    threshold=mx//8
    exp=oracle(a,b,first,mode,threshold)
    fixtures.append((a,b,first,mode,threshold,exp))
    outputs.append(exp)
   if h>1 and label=='temporal_comb':
    assert outputs[0]!=outputs[1] and outputs[1]==outputs[2]
    stats['mode_differences']+=1
   if h>1 and label=='static_linear':
    # Interior linear interpolation must preserve the static raster.
    for y in range(1,h-1):
     for x in range(w):assert outputs[1][y*w+x][0]==int(a[y,x])
   # Threshold maximum permits every missing-line weave candidate.
   fixtures.append((a,b,first,2,mx,oracle(a,b,first,2,mx)))
 stim=[];exp=[]
 for a,b,first,mode,threshold,out in fixtures:
  order=[0] if h==1 else [first,1-first]
  for phase,parity in enumerate(order):
   src=a if phase==0 else b
   for y in range(parity,h,2):
    for x in range(w):
     k=len(stim)%(w*h)
     # Live config changes after the first transfer must have no effect.
     live=(mode,first,threshold) if k==0 else (3,1-first,mx-threshold)
     stim.append((int(src[y,x]),parity,int(y==parity and x==0),int(x==w-1),*live))
  exp+=out;stats['frames']+=1;stats['pixels']+=w*h;stats['bob_pixels']+=sum(v for _,v in out)
 with tempfile.TemporaryDirectory(prefix='deint_') as td:
  td=Path(td)
  def pack(s):
   p,par,sof,eol,mode,first,th=s
   return p|(par<<12)|(sof<<13)|(eol<<14)|(mode<<15)|(first<<17)|(th<<18)
  (td/'input.hex').write_text('\n'.join(f'{pack(s):x}' for s in stim)+'\n')
  (td/'expected.hex').write_text('\n'.join(f'{p|(used<<bits):x}' for p,used in exp)+'\n')
  tb=f'''module tb;
 localparam W={w},H={h},B={bits},N=W*H,F={len(fixtures)},COUNT=N*F;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,s_parity=0,s_field_sof=0,s_eol=0,s_valid=0,m_ready=0;
 reg [B-1:0]s_pixel=0,cfg_threshold=0;reg [1:0]cfg_mode=0;reg cfg_first_parity=0;
 wire s_ready,busy,done,m_valid,m_bob_used,m_sof,m_eol;wire [3:0]error_code;wire [B-1:0]m_pixel;
 deinterlace_fields #(.WIDTH(W),.HEIGHT(H),.BITS(B))dut(.*);
 reg [29:0]ins[0:COUNT-1];reg [B:0]expected[0:COUNT-1];
 integer f,tx,rx,t,cycles,i,target;reg stalled;reg [B+2:0]held;
 task reset;begin @(negedge clk);rst_n=0;ce=0;@(negedge clk);if(m_valid || busy || done || error_code)$fatal(1,"reset leak");rst_n=1;ce=1;s_valid=0;end endtask
 task input_at(input integer k);begin
 s_pixel=ins[k][11:0];s_parity=ins[k][12];s_field_sof=ins[k][13];s_eol=ins[k][14];cfg_mode=ins[k][16:15];cfg_first_parity=ins[k][17];cfg_threshold=ins[k][29:18];
 end endtask
 initial begin
 $readmemh("input.hex",ins);$readmemh("expected.hex",expected);reset;
 for(f=0;f<F;f=f+1)begin
  tx=0;rx=0;cycles=0;stalled=0;
  while(rx<N)begin
   @(negedge clk);ce=(cycles%7!=2);m_ready=(cycles%5!=1);s_valid=(tx<N && cycles%4!=1);
   if(tx<N)input_at(f*N+tx);
   @(posedge clk);
   if(stalled && (!m_valid || held!=={{m_sof,m_eol,m_bob_used,m_pixel}}))$fatal(1,"held output unstable");
   stalled=m_valid && !(ce && m_ready);held={{m_sof,m_eol,m_bob_used,m_pixel}};
   if(ce && s_valid && s_ready)tx=tx+1;
   if(ce && m_valid && m_ready)begin
    if({{m_bob_used,m_pixel}}!==expected[f*N+rx])$fatal(1,"numeric frame %d pixel %d got %d,%d expected %h",f,rx,m_pixel,m_bob_used,expected[f*N+rx]);
    if(m_sof!=(rx==0)||m_eol!=(rx%W==W-1))$fatal(1,"output marker");rx=rx+1;
   end
   #1;if(error_code)$fatal(1,"unexpected error");cycles=cycles+1;if(cycles>50000)$fatal(1,"timeout");
  end
  if(!done || busy)$fatal(1,"completion");
 end
 // Wrong parity on the very first field/header.
 @(negedge clk);ce=1;s_valid=1;cfg_first_parity=0;cfg_mode=0;s_parity=1;s_field_sof=1;s_eol=(W==1);
 @(posedge clk);#1;if(!done || error_code!=1 || busy)$fatal(1,"first parity accepted");
 // Reserved mode must be rejected explicitly.
 @(negedge clk);cfg_mode=3;s_parity=0;@(posedge clk);#1;if(!done || error_code!=2 || busy)$fatal(1,"reserved mode");
 // Wrong marker at the first pixel, followed by partial-frame reset.
 @(negedge clk);cfg_mode=0;s_field_sof=0;@(posedge clk);#1;if(!done || error_code!=1)$fatal(1,"bad sof");
 @(negedge clk);input_at(0);s_valid=1;@(posedge clk);#1;reset;
 // Change parity prematurely inside a field (or at first pixel for one-pixel fields).
 @(negedge clk);input_at(0);s_valid=1;@(negedge clk);
 if(N>1)begin input_at(1);s_parity=!s_parity;@(posedge clk);#1;if(!done || error_code!=1 || busy)$fatal(1,"mid-field parity");end
 reset;
 // Odd-height first field has ceil(H/2) lines: early second header must abort.
 if(H>2 && H%2==1)begin
  for(i=0;i<W*((H-1)/2);i=i+1)begin @(negedge clk);input_at(i);s_valid=1;end
  @(negedge clk);s_parity=1;s_field_sof=1;s_eol=(W==1);@(posedge clk);#1;
  if(!done || error_code!=1 || busy)$fatal(1,"odd short top field");reset;
  for(i=0;i<W*((H-1)/2);i=i+1)begin @(negedge clk);input_at((F/2)*N+i);s_valid=1;end
  @(negedge clk);s_parity=1;s_field_sof=0;s_eol=(W==1);@(posedge clk);#1;
  if(!done || error_code!=1 || busy)$fatal(1,"odd overlong bottom field");reset;
 end
 @(negedge clk);input_at(0);s_eol=!s_eol;s_valid=1;@(posedge clk);#1;
 if(!done || error_code!=1 || busy)$fatal(1,"bad EOL");reset;
 // A complete good replay after faults, checked against the oracle.
 tx=0;rx=0;m_ready=1;ce=1;
 while(rx<N)begin
  @(negedge clk);s_valid=(tx<N);if(tx<N)input_at(tx);
  @(posedge clk);if(s_valid&&s_ready)tx=tx+1;
  if(m_valid&&m_ready)begin if({{m_bob_used,m_pixel}}!==expected[rx])$fatal(1,"recovery replay");rx=rx+1;end
 end
 reset;
 // Reset after synchronous-read and while an output record is held.
 for(target=2;target<=9;target=target+7)begin
  for(i=0;i<N;i=i+1)begin @(negedge clk);input_at(i);s_valid=1;end
  @(negedge clk);s_valid=0;m_ready=0;t=0;
  while(dut.state!=target)begin @(negedge clk);t=t+1;if(t>1000)$fatal(1,"reset reach");end
  reset;
 end
 $display("DEINTERLACE PASS");$finish;
 end
 initial begin #100000000;$fatal(1,"watchdog");end
 endmodule'''
  (td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'deinterlace_fields.sv',td/'tb.sv'],td,td/'compile.log')
  assert 'DEINTERLACE PASS' in execute(['vvp',td/'sim'],td,td/'sim.log')
 print((w,h,bits),'PASS')
def guards():
 cases=('.WIDTH(0)','.HEIGHT(4097)','.WIDTH(4096),.HEIGHT(17)','.BITS(7)','.BITS(13)')
 with tempfile.TemporaryDirectory(prefix='deint_guards_') as td:
  td=Path(td)
  for cfg in cases:
   (td/'tb.sv').write_text(f'module bad;deinterlace_fields #({cfg}) dut();initial begin #10;$fatal(1,"guard missing");end endmodule')
   execute(['iverilog','-g2012','-s','bad','-o',td/'sim',HERE/'deinterlace_fields.sv',td/'tb.sv'],td,td/'compile.log')
   try:execute(['vvp',td/'sim'],td,td/'sim.log')
   except RuntimeError:assert 'invalid deinterlace parameters' in (td/'sim.log').read_text()
   else:raise AssertionError('invalid accepted')
 stats['invalid_parameter_cases']=len(cases)
if __name__=='__main__':
 for cfg in ((7,6,8),(5,5,12),(1,7,10),(9,2,8),(2,3,12),(7,1,8),(1,1,12)):run(*cfg)
 guards()
 result={'result':'PASS',**stats,'oracle':'independent Python integer paired-field raster/linear BOB/adaptive threshold model','board':False,'rtl_sha256':hashlib.sha256((HERE/'deinterlace_fields.sv').read_bytes()).hexdigest()}
 (HERE/'evidence.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
