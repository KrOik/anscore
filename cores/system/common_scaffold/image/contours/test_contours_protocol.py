"""Reset recovery and static parameter rejection without persistent builds."""
import subprocess,tempfile,json
from pathlib import Path
from test_contours import ROOT
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,s_pixel=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;
wire s_ready,m_valid,m_contour_start,m_contour_end,m_hole,done_valid,busy;
wire[2:0]m_x,m_y;wire[1:0]m_dir,error_code;wire signed[31:0]m_area2;
wire[4:0]m_contour_index,foreground_count,contour_count;wire[6:0]m_edge_index,edge_count;
contours_cell_edges #(.WIDTH(4),.HEIGHT(4))dut(.*);
integer i,outs=0,ends=0;
always @(posedge clk)if(!rst&&ce&&m_valid&&m_ready)begin
 outs=outs+1;if(m_contour_end)begin ends=ends+1;if(m_area2!=32||m_hole)$fatal(1,"area/hole");end
end
task reset_abort;begin @(negedge clk);rst=1;ce=0;@(posedge clk);#1;if(busy||m_valid||done_valid)$fatal(1,"reset CE0");@(negedge clk);rst=0;ce=1;s_valid=0;end endtask
task pixel(input integer n);begin @(negedge clk);s_valid=1;s_sof=n==0;s_eol=n%4==3;@(negedge clk);s_valid=0;end endtask
task frame;begin for(i=0;i<16;i=i+1)pixel(i);end endtask
initial begin repeat(3)@(negedge clk);rst=0;pixel(0);reset_abort;
frame;wait(dut.state==4);reset_abort;
frame;wait(dut.state==8);reset_abort;
frame;wait(m_valid);repeat(3)@(negedge clk);reset_abort;
frame;m_ready=1;wait(done_valid);@(negedge clk);m_ready=0;reset_abort;
outs=0;ends=0;frame;m_ready=1;wait(done_valid);#1;if(outs!=16||ends!=1||edge_count!=16||foreground_count!=16||contour_count!=1||error_code)$fatal(1,"recovery");
repeat(3)@(negedge clk);done_ready=1;@(negedge clk);done_ready=0;if(busy)$fatal;$display("PASS reset recovery");$finish;end
initial begin #1000000;$fatal(1,"timeout");end
endmodule'''
def main():
 with tempfile.TemporaryDirectory(prefix='contours_protocol_') as td:
  td=Path(td)
  def compile_run(text):
   (td/'tb.sv').write_text(text)
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'contours_cell_edges.v'),str(td/'tb.sv')],cwd=td,capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   return subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True,timeout=30)
  p=compile_run(TB)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  for w,h in [(0,1),(1,0),(65,65),(4097,1)]:
   p=compile_run(f'module tb;contours_cell_edges #(.WIDTH({w}),.HEIGHT({h}))dut();initial begin #1;$finish;end endmodule')
   if p.returncode==0 or 'invalid contours geometry' not in p.stdout:raise AssertionError((w,h,p.stdout))
 result=dict(status='PASS',reset_ce0_phases=['capture','build','scan','held_output','held_done'],recovery_edges=16,invalid_static_parameters=4)
 (ROOT/'protocol_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
if __name__=='__main__':main()
