"""Reset, malformed markers, start snapshot and held completion protocol."""
import json,subprocess,tempfile
from pathlib import Path
from test_jpeg_color_mcu import ROOT
TB='''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,cfg_sampling_420=1,s_valid=0,s_sof=0,s_eol=0,m_ready=1,done_ready=0;
reg[23:0]s_rgb=24'hff0000;wire start_ready,s_ready,m_valid,m_block_first,m_block_last,m_frame_last,m_mcu_last,done_valid,busy;wire[7:0]m_data;wire[1:0]m_component;wire[31:0]m_mcu_index;wire[3:0]error_code;
jpeg_color_mcu #(.WIDTH(8),.HEIGHT(9))dut(.*);
integer i,f,received=0,frame_last_count=0,mode=0;reg check_output=0;
always @(posedge clk)if(rst_n&&ce&&m_valid&&m_ready&&check_output)begin
 if(m_data!==(m_component==0?8'd76:m_component==1?8'd85:8'd255))$fatal(1,"red conversion");
 if(m_frame_last)frame_last_count=frame_last_count+1;received=received+1;end
task start;begin @(negedge clk);start_valid=1;cfg_sampling_420=1;@(negedge clk);start_valid=0;cfg_sampling_420=0;end endtask
task pixel(input integer n,input integer err);begin
 @(negedge clk);s_valid=1;s_sof=(n==0&&err!=1)||(err==2&&n==3);s_eol=(n%8==7&&!(err==3&&n==7))||(err==4&&n==3);
 @(negedge clk);s_valid=0;end endtask
task frame(input integer err);begin start;for(i=0;i<72;i=i+1)pixel(i,err);end endtask
task reset_abort;begin @(negedge clk);rst_n=0;ce=0;s_valid=0;start_valid=0;@(posedge clk);#1;if(busy||done_valid||m_valid||start_ready||s_ready)$fatal(1,"CE0 reset");@(negedge clk);rst_n=1;ce=1;end endtask
task acknowledge;begin repeat(3)@(negedge clk);done_ready=1;@(negedge clk);done_ready=0;end endtask
initial begin repeat(3)@(negedge clk);reset_abort;
start;pixel(0,0);pixel(1,0);reset_abort;
frame(0);wait(dut.state==4);reset_abort;
frame(0);wait(dut.subsample==2&&dut.state==5);reset_abort;
m_ready=0;frame(0);wait(m_valid);repeat(3)@(negedge clk);reset_abort;
m_ready=1;frame(0);wait(done_valid);reset_abort;
for(f=1;f<=4;f=f+1)begin
 received=0;check_output=1;frame(f);wait(done_valid);#1;if(error_code!=1||received)$fatal(1,"bad marker frame output");acknowledge;
 received=0;frame_last_count=0;frame(0);wait(done_valid);#1;if(error_code||received!=384||frame_last_count!=1)$fatal(1,"bad frame recovery");acknowledge;
end
if(busy)$fatal;$display("PASS reset + four malformed-marker recovery frames");$finish;end
initial begin #10000000;$fatal(1,"timeout");end endmodule'''
def main():
 with tempfile.TemporaryDirectory(prefix='jpeg_color_protocol_') as temporary:
  td=Path(temporary)
  def run(text):
   (td/'tb.sv').write_text(text)
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'jpeg_color_mcu.v'),str(td/'tb.sv')],cwd=td,capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   return subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True,timeout=60)
  p=run(TB)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  for width,height in [(0,1),(1,0),(65537,1),(257,256)]:
   p=run(f'module tb;jpeg_color_mcu #(.WIDTH({width}),.HEIGHT({height}))dut();initial begin #1;$finish;end endmodule')
   assert p.returncode and 'invalid JPEG color MCU geometry' in p.stdout
 result=dict(status='PASS',ce0_reset_phases=['idle','capture','synchronous_read','chroma_accumulate','held_output','held_done'],malformed_marker_modes=['missing_sof','extra_sof','missing_eol','extra_eol'],recovery_frames=4,recovery_samples=1536,invalid_geometry_cases=4)
 (ROOT/'protocol_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result,flush=True)
if __name__=='__main__':main()
