"""CE=0 reset aborts all major phases, then complete frame recovery."""
import json,subprocess,tempfile
from pathlib import Path
from test_pyramidal_flow import ROOT
TB='''module tb;
reg clk=0;always #5 clk=~clk;reg rst=1,ce=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;
reg[7:0]s_ref=0,s_cur=0;wire s_ready,m_valid,m_texture_invalid,m_oob,m_overflow,m_invalid,m_sof,m_eol,m_last,done_valid,busy;
wire signed[15:0]m_flow_x,m_flow_y;wire[2:0]m_x,m_y;wire[1:0]error_code;
pyramidal_lk_flow #(.WIDTH(8),.HEIGHT(8),.LEVELS(2),.WINDOW(3),.ITERATIONS(1))dut(.*);
integer i,received=0;
always @(posedge clk)if(!rst&&ce&&m_valid&&m_ready)begin
 if(m_flow_x||m_flow_y||m_x!=received%8||m_y!=received/8)$fatal(1,"recovery flow/coordinate");received=received+1;end
task pixel(input integer n);begin @(negedge clk);s_valid=1;s_ref=(n*37+n/8*13)%256;s_cur=s_ref;s_sof=n==0;s_eol=n%8==7;@(negedge clk);s_valid=0;end endtask
task frame;begin for(i=0;i<64;i=i+1)pixel(i);end endtask
task abort_reset;begin @(negedge clk);rst=1;ce=0;@(posedge clk);#1;if(busy||done_valid||m_valid)$fatal(1,"reset CE0");@(negedge clk);rst=0;ce=1;s_valid=0;end endtask
initial begin repeat(3)@(negedge clk);rst=0;pixel(0);abort_reset;
frame;wait(dut.state==4);abort_reset;
frame;wait(dut.state==23);abort_reset;
frame;wait(dut.state==26);abort_reset;
frame;wait(dut.state==18);abort_reset;
frame;wait(m_valid);repeat(3)@(negedge clk);abort_reset;
frame;m_ready=1;wait(done_valid);@(negedge clk);m_ready=0;abort_reset;
received=0;frame;m_ready=1;wait(done_valid);#1;if(received!=64||error_code)$fatal(1,"recovery status");
repeat(3)@(negedge clk);done_ready=1;@(negedge clk);done_ready=0;if(busy)$fatal;$display("PASS reset recovery");$finish;end
initial begin #100000000;$fatal(1,"timeout");end endmodule'''
EDGE_TB='''module tb;
reg clk=0;always #5 clk=~clk;reg rst=1,ce=1,s_valid=0,s_sof=0,s_eol=0,m_ready=1,done_ready=0;
reg[7:0]s_ref=0,s_cur=0;wire s_ready,m_valid,m_texture_invalid,m_oob,m_overflow,m_invalid,m_sof,m_eol,m_last,done_valid,busy;
wire signed[15:0]m_flow_x,m_flow_y;wire[2:0]m_x,m_y;wire[1:0]error_code;
pyramidal_lk_flow #(.WIDTH(8),.HEIGHT(8),.LEVELS(2),.WINDOW(3),.ITERATIONS(1),.MAX_STEP_Q(128),.DET_THRESHOLD(0))dut(.*);
integer i,f,received=0;reg bad;
always @(posedge clk)if(!rst&&ce&&m_valid&&m_ready)begin
 if(bad)$fatal(1,"malformed frame emitted output");
 if(m_flow_x||m_flow_y||m_oob||m_overflow||m_x!=received%8||m_y!=received/8)$fatal(1,"edge fixture output");
 if(f!=1&&!m_texture_invalid)$fatal(1,"det exactly threshold0 must reject");
 received=received+1;end
initial begin repeat(3)@(negedge clk);rst=0;
for(f=0;f<5;f=f+1)begin bad=f==2||f==3;received=0;
 for(i=0;i<64;i=i+1)begin
  @(negedge clk);s_valid=1;s_sof=(i==0)||(f==2&&i==3);s_eol=(i%8==7)||(f==3&&i==3);
  s_ref=f==1?(i*37+i/8*13)%256:55;s_cur=f==0?77:s_ref;
  @(negedge clk);s_valid=0;
 end
 wait(done_valid);#1;if(error_code!=bad||received!=(bad?0:64))$fatal(1,"edge fixture status");
 repeat(3)@(negedge clk);done_ready=1;@(negedge clk);done_ready=0;
end
$display("PASS max-step128, det-equality, extra SOF/internal EOL recovery");$finish;end
initial begin #100000000;$fatal(1,"timeout");end endmodule'''
def main():
 with tempfile.TemporaryDirectory(prefix='pyramidal_protocol_') as temporary:
  td=Path(temporary)
  def run(text):
   (td/'tb.sv').write_text(text)
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'pyramidal_lk_flow.v'),str(td/'tb.sv')],cwd=td,capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   return subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True,timeout=180)
  p=run(TB)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  p=run(EDGE_TB)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  invalid=['.WIDTH(7)','.HEIGHT(33)','.LEVELS(1)','.LEVELS(4)','.WINDOW(1)','.ITERATIONS(0)','.ITERATIONS(5)','.MAX_FLOW_Q(32768)','.MAX_STEP_Q(0)','.MAX_STEP_Q(129)','.DET_THRESHOLD(-1)']
  for parameters in invalid:
   p=run(f'module tb;pyramidal_lk_flow #({parameters})dut();initial begin #1;$finish;end endmodule')
   assert p.returncode!=0 and 'invalid pyramidal LK parameters' in p.stdout,parameters
 result=dict(status='PASS',ce0_reset_phases=['capture','gaussian','multiply','divide','warp','held_output','held_done'],recovery_pixels=64,invalid_static_cases=len(invalid),narrow_frames=5,narrow_output_pixels=192,max_step_128='PASS',det_equal_threshold_zero='PASS',extra_sof_and_internal_eol_recovery='PASS')
 (ROOT/'protocol_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result,flush=True)
if __name__=='__main__':main()
