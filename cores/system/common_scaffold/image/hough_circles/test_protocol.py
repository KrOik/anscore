import tempfile,subprocess
from pathlib import Path
import numpy as np
from run_tests import ROOT,simulate,frame_body
from oracle import accumulator
def run():
 edges=np.ones((5,7),np.uint8);good,_=frame_body(edges,(1,4,6,4,2,2));body=[]
 for phase in (1,2,3,5,7,9,14,17,19,20):
  body.append('beginframe(1,4,6,4,2,2);')
  if phase in (3,5,7,9):body.append('send(1,1,0);')
  elif phase in (14,17,19,20):
   for y in range(5):
    for x in range(7):body.append(f'send(1,{int(x==y==0)},{int(x==6)});')
  if phase in (19,20):body.append('m_ready=1;')
  body.append(f'while(dut.state!={phase})@(negedge clk);ce=0;rst=1;@(negedge clk);if(busy||m_valid||done_valid||done_error||error_code||done_count||s_ready||start_ready)$fatal(1,"reset phase {phase}");rst=0;ce=1;m_ready=0;')
  body.append(good)
 invalid=[(0,4,1,1,0,0),(1,0,1,1,0,0),(1,5,1,1,0,0),(3,2,1,1,0,0),(1,4,0,1,0,0),(1,4,1,0,0,0),(1,4,1,9,0,0),(1,4,1,1,32,0),(1,4,1,1,0,32)]
 for cfg in invalid:body.append(f'beginframe({",".join(map(str,cfg))});finish_frame(0,16);')
 body.append(good)
 print(simulate('\n'.join(body),7,5,4))
 # Highest legal output count exercises index31 and terminal count32 without wrap.
 large,_=frame_body(edges,(1,4,1,32,0,0));print(simulate(large,7,5,4,32))
 # Check every pre-NMS RTL accumulator bin against exhaustive center search.
 noise=(np.random.default_rng(7123).random((5,7))<.4).astype(np.uint8)
 fixture,_=frame_body(noise,(1,4,2,8,1,1));expected=accumulator(noise,1,4)
 inspect='while(dut.state!=13)@(negedge clk);ce=0;\n'
 for address,value in enumerate(expected.ravel()):inspect+=f'if(dut.accumulator[{address}]!==8\'d{int(value)})$fatal(1,"full accumulator bin {address}");\n'
 inspect+='@(negedge clk);ce=1;\n'
 fixture=fixture.replace('check_circle(',inspect+'check_circle(',1)
 print(simulate(fixture,7,5,4))
 with tempfile.TemporaryDirectory(prefix='circles_bad_') as td:
  td=Path(td)
  for w,h,mr,mc in ((0,1,1,1),(1,0,1,1),(33,1,1,1),(1,33,1,1),(1,1,0,1),(1,1,32,1),(1,1,1,0),(1,1,1,33)):
   (td/'bad.v').write_text(f'module bad;hough_circles_frame #(.WIDTH({w}),.HEIGHT({h}),.MAX_RADIUS({mr}),.MAX_CIRCLES({mc})) dut();endmodule')
   p=subprocess.run(['iverilog','-g2012','-s','bad','-o',str(td/'sim'),str(ROOT/'hough_circles_frame.v'),str(td/'bad.v')],cwd=ROOT,capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   p=subprocess.run(['vvp',str(td/'sim')],cwd=ROOT,capture_output=True,text=True)
   assert p.returncode!=0 and 'invalid Hough-circle static parameters' in p.stdout
 print('PROTOCOL PASS reset_phases=10 healthy_recovery=11 invalid_configs=9 invalid_static=8 max_count32=PASS full_accumulator_bins=140')
if __name__=='__main__':run()
