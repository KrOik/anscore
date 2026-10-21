import subprocess,tempfile
from pathlib import Path
from run_tests import ROOT,simulate,pack
from oracle import oracle
def run():
 body=[]
 for inv in (False,True):
  for bad in range(5):
   body.append(f'startframe({int(inv)});')
   for j in range(6):
    p=(23+j*35,219-j*29,91+j*17);e=oracle(p,inv)
    sof=int(j==0);eol=int(j%3==2)
    if bad==1 and j==0:sof=0
    if bad==2 and j==2:sof=1
    if bad==3 and j==1:eol=1
    if bad==4 and j==5:eol=0
    body.append(f"pixel(24'h{pack(p):06x},24'h{pack(e):06x},{sof},{eol},{int(j==0)},{int(j%3==2)});")
   body.append(f'ack({[0,1,2,8,4][bad]});')
 print(simulate('\n'.join(body),3,2))
 body=[];p=(91,182,213);e=oracle(p)
 for phase in (1,2,6,10,18,24,25,22,23):
  body.append('startframe(0);')
  if phase!=1:
   body.append(f"s_data=24'h{pack(p):06x};s_sof=1;s_eol=1;s_valid=1;@(negedge clk);s_valid=0;")
  if phase==23:body.append('m_ready=1;')
  body.append(f'while(dut.state!={phase})@(negedge clk);ce=0;rst=1;@(negedge clk);if(busy||m_valid||done_valid||done_error||error_code||s_ready||start_ready)$fatal(1,"reset phase {phase}");rst=0;ce=1;m_ready=0;')
  body.append(f"frame(0,24'h{pack(p):06x},24'h{pack(e):06x});")
 print(simulate('\n'.join(body)))
 with tempfile.TemporaryDirectory(prefix='lab_bad_geometry_') as td:
  td=Path(td)
  for w,h in ((0,1),(1,0),(257,256),(65537,1)):
   (td/'bad.v').write_text(f'module bad;rgb_cielab_stream #(.WIDTH({w}),.HEIGHT({h})) dut();endmodule')
   subprocess.run(['iverilog','-g2012','-s','bad','-o',str(td/'bad'),str(ROOT/'rgb_cielab_stream.v'),str(td/'bad.v')],cwd=ROOT,capture_output=True,check=True)
   p=subprocess.run(['vvp',str(td/'bad')],cwd=ROOT,capture_output=True,text=True)
   assert p.returncode!=0 and 'invalid CIELAB geometry' in p.stdout
 print('PROTOCOL PASS frames=10 pixels=60 reset_phases=9 recovery_frames=9 invalid_geometry=4')
if __name__=='__main__':run()
