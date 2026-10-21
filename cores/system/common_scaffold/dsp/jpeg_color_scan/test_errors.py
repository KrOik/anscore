from pathlib import Path
import tempfile,json
from test_color_scan import HERE,SOURCES,execute
TB='''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1;
 reg table_id=0,table_valid=0,cfg_valid=0,start_valid=0,abort=0,s_valid=0,m_ready=1,done_ready=0;
 reg [5:0]table_index=0;reg [7:0]table_value=8,s_data=128;reg [1:0]s_component=0;
 reg [31:0]cfg_total_mcus=1;reg [15:0]cfg_restart_interval=0;reg cfg_sampling_420=0;
 reg s_block_first=0,s_block_last=0,s_frame_last=0;
 wire table_ready,cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_marker,m_scan_last,done_valid,busy;
 wire [7:0]m_data,error_code;jpeg_color_scan dut(.*);integer i,j,k,t;reg [7:0]held_error;reg watched;
 task reset;begin @(negedge clk);rst_n=0;ce=0;@(negedge clk);if(m_valid||done_valid||busy)$fatal(1,"reset leak");rst_n=1;ce=1;s_valid=0;start_valid=0;abort=0;m_ready=1;done_ready=0;cfg_total_mcus=1;cfg_sampling_420=0;end endtask
 task configure;begin
 for(j=0;j<2;j=j+1)for(i=0;i<64;i=i+1)begin @(negedge clk);table_valid=1;table_id=j;table_index=i;end
 @(negedge clk);table_valid=0;cfg_valid=1;@(negedge clk);cfg_valid=0;wait(cfg_done);@(negedge clk);end endtask
 task start;begin @(negedge clk);start_valid=1;if(!start_ready)$fatal(1,"start blocked");@(negedge clk);start_valid=0;end endtask
 task pixel(input integer n,input integer component,input integer bf,input integer bl,input integer fl);begin
 @(negedge clk);s_data=n;s_component=component;s_block_first=bf;s_block_last=bl;s_frame_last=fl;s_valid=1;
 @(posedge clk);while(!s_ready)@(posedge clk);@(negedge clk);s_valid=0;end endtask
 task check_error(input [7:0]expected);begin
 t=0;while(!done_valid)begin @(negedge clk);t=t+1;if(t>1000)$fatal(1,"error timeout");end
 if(error_code!==expected||s_ready)$fatal(1,"error got%h expected%h",error_code,expected);
 held_error=error_code;repeat(4)begin @(negedge clk);ce=0;if(!done_valid||error_code!==held_error)$fatal(1,"error held");end
 ce=1;done_ready=1;@(negedge clk);done_ready=0;
 end endtask
 initial begin
 for(k=0;k<7;k=k+1)begin
 reset;configure;
 if(k==5)cfg_total_mcus=0;
 if(k==6)begin cfg_total_mcus=32'hffffffff;cfg_sampling_420=1;end
 start;
 case(k)
 0:begin pixel(128,1,1,0,0);check_error(8'h81);end
 1:begin pixel(128,0,0,0,0);check_error(8'h81);end
 2:begin pixel(128,0,1,1,0);check_error(8'h81);end
 3:begin pixel(128,0,1,0,1);check_error(8'h81);end
 4:begin pixel(128,0,1,0,0);abort=1;check_error(8'h86);end
 5,6:check_error(8'h87);
 endcase
 end
 // Reset during table reload, DCT multiply, quant divide, held byte, held DONE.
 for(k=0;k<5;k=k+1)begin
 reset;configure;start;
 if(k==0)begin wait(dut.reload_state==2);reset;end
 else if(k==1 || k==2)begin
  for(i=0;i<64;i=i+1)pixel(170,0,i==0,i==63,0);
  if(k==1)wait(dut.dct.state==2);else wait(dut.quant.state==7);reset;
 end else begin
  // Concurrent source and phase watcher avoid deadlock on held output.
  watched=0;fork
   begin for(i=0;i<192;i=i+1)pixel(160+(i/64)*5,i/64,i%64==0,i%64==63,i==191);end
   begin
    if(k==3)begin m_ready=0;wait(m_valid);end else wait(done_valid);
    @(negedge clk);rst_n=0;ce=0;@(negedge clk);if(m_valid||done_valid||busy)$fatal(1,"held reset");watched=1;
   end
  join_none
  wait(watched);
  disable fork;
 end
 end
 $display("JPEG COLOR ERRORS PASS");$finish;end
 initial begin #100000000;$fatal(1,"watchdog");end endmodule'''
if __name__=='__main__':
 with tempfile.TemporaryDirectory(prefix='color_scan_errors_') as td:
  td=Path(td);(td/'tb.sv').write_text(TB,encoding='utf-8')
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
  assert 'JPEG COLOR ERRORS PASS' in execute(['vvp',td/'sim'],td,td/'simulation.log',timeout=120)
 result={'result':'PASS','error_cases':['wrong component','block_first','block_last','frame_last','abort','zero MCUs','32bit block-count overflow'],'reset_phases':['table reload','DCT MAC','quant divide','held byte','held DONE'],'board':False}
 (HERE/'error_evidence.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
