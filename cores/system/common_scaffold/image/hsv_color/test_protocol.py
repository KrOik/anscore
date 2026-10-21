"""Multi-line frame markers, sticky errors, recovery, abort reset and invalid geometry."""
import subprocess,tempfile
from pathlib import Path
from test_hsv_color import ROOT,oracle
def run():
 with tempfile.TemporaryDirectory(prefix='hsv_protocol_') as d:
  d=Path(d)
  cases=[]
  for inv in (0,1):
   for bad in range(5):
    cases.append(f'beginframe({inv});')
    for j in range(6):
     v=(17+j*37,220-j*29,255-j*23);out=oracle(v,inv)
     pack=lambda x:sum(int(y)<<s for y,s in zip(x,(16,8,0)))
     sof=int(j==0);eol=int(j%3==2)
     if bad==1 and j==0:sof=0
     if bad==2 and j==3:sof=1
     if bad==3 and j==1:eol=1
     if bad==4 and j==5:eol=0
     cases.append(f'pixel(24\'h{pack(v):06x},24\'h{pack(out):06x},{sof},{eol},{int(j==0)},{int(j%3==2)});')
    code=[0,1,2,8,4][bad]
    cases.append(f'if(!done||!done_valid||!busy||error!={int(bad!=0)}||error_code!={code})$fatal(1,"terminal error");@(negedge clk);if(busy||done_valid)$fatal(1,"ack");')
  tb='''module tb;reg clk=0;always #5 clk=~clk;reg rst=1,ce=1,start_valid=0,cfg_inverse=0,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=1;wire done_valid;wire[3:0]error_code;reg[23:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,done,error,busy;wire[23:0]m_data;
 rgb_hsv_full_stream #(.WIDTH(3),.HEIGHT(2)) dut(.*);
 task beginframe;input inv;begin @(negedge clk);start_valid=1;cfg_inverse=inv;@(negedge clk);start_valid=0;cfg_inverse=!inv;if(done||error)$fatal(1,"start clear");end endtask
 task pixel;input[23:0]v,e;input sf,el,os,oe;begin
 s_data=v;s_sof=sf;s_eol=el;s_valid=1;while(!s_ready)@(negedge clk);@(negedge clk);s_valid=0;
 while(!m_valid)@(negedge clk);if(m_data!==e||m_sof!=os||m_eol!=oe)$fatal(1,"pixel/marker");
 m_ready=1;@(negedge clk);m_ready=0;end endtask
 integer k;
 initial begin repeat(2)@(negedge clk);rst=0;
 '''+'\n'.join(cases)+'''
 done_ready=0;beginframe(0);
 pixel(0,0,1,0,1,0);pixel(0,0,0,0,0,0);pixel(0,0,0,1,0,1);
 pixel(0,0,0,0,0,0);pixel(0,0,0,0,0,0);pixel(0,0,0,1,0,1);
 if(!done_valid)$fatal(1,"completion missing");ce=0;rst=1;@(negedge clk);
 if(done_valid||busy)$fatal(1,"completion reset");rst=0;ce=1;done_ready=1;
 for(k=1;k<=5;k=k+1)begin
 beginframe(0);s_valid=1;s_data=24'hfe1278;s_sof=1;s_eol=0;@(negedge clk);s_valid=0;
 while(dut.state!=k)begin
 if(k==1)begin m_ready=1;end
 @(negedge clk);end
 ce=0;rst=1;@(negedge clk);if(busy||m_valid||done||error)$fatal(1,"reset failed");rst=0;ce=1;m_ready=0;
 end
 $display("PROTOCOL PASS frames=11 pixels=66 reset_phases=6");$finish;end
 initial begin #1000000;$fatal(1,"timeout");end endmodule'''
  (d/'tb.v').write_text(tb)
  subprocess.run(['iverilog','-g2012','-s','tb','-o',str(d/'sim'),str(ROOT/'rgb_hsv_full_stream.v'),str(d/'tb.v')],check=True,capture_output=True)
  p=subprocess.run(['vvp',str(d/'sim')],capture_output=True,text=True,timeout=30)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  print(p.stdout)
  for w,h in ((0,1),(1,0),(257,256),(65537,1)):
   (d/'bad.v').write_text(f'module bad;rgb_hsv_full_stream #(.WIDTH({w}),.HEIGHT({h})) dut();endmodule')
   subprocess.run(['iverilog','-g2012','-s','bad','-o',str(d/'bad'),str(ROOT/'rgb_hsv_full_stream.v'),str(d/'bad.v')],check=True,capture_output=True)
   p=subprocess.run(['vvp',str(d/'bad')],capture_output=True,text=True)
   assert p.returncode!=0 and 'invalid geometry' in p.stdout
 print('PASS invalid geometries=4')
if __name__=='__main__':run()

