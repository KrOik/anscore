"""Abort capture, queue scan, flood, held output and DONE under CE=0."""
import subprocess,tempfile,json
from test_watershed import ROOT
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,cfg_connect8=1,s_valid=0,s_sof=0,s_eol=0,s_domain=1,m_ready=0,done_ready=0;
reg[7:0] s_elevation=0,s_seed=0;wire s_ready,m_valid,m_sof,m_eol,m_last,m_domain,m_invalid,done_valid,busy;wire[7:0]m_label;wire[3:0]error_code;
wire[1:0]m_x,m_y;wire[4:0]seed_count,assigned_count,popped_count;
watershed_priority_frame #(.WIDTH(4),.HEIGHT(4)) dut(.*);
integer i,j,outs=0;
always @(posedge clk)if(!rst&&ce&&m_valid&&m_ready)begin if(m_label!=9||m_invalid)$fatal(1,"recovery label");outs=outs+1;end
task abort_reset;begin @(negedge clk);ce=0;rst=1;@(posedge clk);#1;if(busy||m_valid||done_valid)$fatal(1,"CE0 reset failed");@(negedge clk);rst=0;ce=1;s_valid=0;end endtask
task pixel(input integer n);begin @(negedge clk);s_valid=1;s_elevation=15-n;s_seed=(n==0?9:0);s_sof=(n==0);s_eol=(n%4==3);@(negedge clk);s_valid=0;end endtask
task frame;begin for(i=0;i<16;i=i+1)pixel(i);end endtask
initial begin repeat(3)@(negedge clk);rst=0;pixel(0);pixel(1);abort_reset;
frame;wait(dut.state==4);abort_reset;
frame;wait(dut.state==10);abort_reset;
frame;wait(m_valid);repeat(4)@(negedge clk);abort_reset;
frame;wait(m_valid);m_ready=1;wait(done_valid);@(negedge clk);m_ready=0;abort_reset;
outs=0;frame;m_ready=1;wait(done_valid);#1;if(outs!=16||error_code||assigned_count!=16||popped_count!=16)$fatal(1,"final recovery");
repeat(3)@(negedge clk);done_ready=1;@(negedge clk);done_ready=0;if(busy)$fatal;$display("PASS 5 reset points + recovery");$finish;end
initial begin #1000000;$fatal(1,"timeout");end
endmodule'''
def main():
 with tempfile.TemporaryDirectory(prefix='watershed_protocol_') as td:
  from pathlib import Path
  td=Path(td);(td/'tb.sv').write_text(TB)
  p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'watershed_priority_frame.v'),str(td/'tb.sv')],cwd=td,capture_output=True,text=True)
  if p.returncode:raise RuntimeError(p.stderr)
  p=subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 (ROOT/'protocol_result.json').write_text(json.dumps({'status':'PASS','ce0_reset_points':['capture','scan','push','held_output','done'],'recovery_pixels':16},indent=2)+'\n');print(p.stdout.strip())
if __name__=='__main__':main()
