"""Marker termination, all processing-stage aborts, CE-disabled reset and healthy recovery."""
import tempfile,json
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[1:0]cfg_pattern=0;reg[7:0]s_data=37;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;
wire[23:0]m_data;wire[7:0]error_code;
malvar_demosaic #(.WIDTH(5),.HEIGHT(3),.BITS(8)) dut(.*);
integer cyc=0,got=0,test,target,i;reg[26:0]held;reg stalled=0;
wire[26:0]token={m_last,m_eol,m_sof,m_data};
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%7<4;if(cyc>100000)$fatal(1,"timeout %d",dut.state);end
always @(posedge clk)if(rst_n)begin
 if(!abort&&stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=!abort&&m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin if(m_data!==24'h252525)$fatal(1,"pixel %d",m_data);
 if(m_sof!==(got%15==0)||m_eol!==((got%5)==4)||m_last!==(got%15==14))$fatal(1,"markers");got=got+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 task launch;begin start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;end endtask
 task sendframe;integer k;begin
 for(k=0;k<15;k=k+1)begin s_data=37;s_sof=k==0;s_eol=k%5==4;s_last=k==14;s_valid=1;while(!s_ready&&!done_valid)tick;if(done_valid)k=15;else begin @(posedge clk);#1;tick;end end s_valid=0;end endtask
 task acknowledge;input integer err,code;begin
 while(!done_valid)tick;if(done_error!==err[0]||(err&&error_code!=code))$fatal(1,"done %h",error_code);
 repeat(5)tick;done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;end endtask
 task healthy;input integer count;begin launch;sendframe;acknowledge(0,0);if(got!=count)$fatal(1,"count%d",got);end endtask
 initial begin repeat(3)tick;rst_n=1;tick;
 for(test=1;test<=6;test=test+1)begin
 launch;force m_ready=0;
 if(test!=1)sendframe;
 while(dut.state!=test)tick;abort=1;while(!ce)tick;@(posedge clk);#1;tick;abort=0;release m_ready;
 acknowledge(1,8'h93);cfg_pattern=test%4;healthy(15*test);
 end
 // Malformed first token returns immediately, no need to complete source frame.
 launch;s_valid=1;s_sof=0;s_eol=0;s_last=0;while(!s_ready)tick;@(posedge clk);#1;tick;s_valid=0;acknowledge(1,8'h81);healthy(105);
 // Wrong EOL on an otherwise correctly located first sample.
 launch;s_valid=1;s_sof=1;s_eol=1;s_last=0;while(!s_ready)tick;@(posedge clk);#1;tick;s_valid=0;acknowledge(1,8'h81);healthy(120);
 // Reset mid-convolution, CE=0.
 launch;force m_ready=0;sendframe;while(dut.state!=4)tick;force ce=0;rst_n=0;@(posedge clk);#1;if(busy||done_valid||m_valid)$fatal(1,"reset while disabled");tick;rst_n=1;release ce;release m_ready;got=0;stalled=0;tick;healthy(15);
 $display("PASS malvar protocol");$finish;end
endmodule
'''
def main():
 with tempfile.TemporaryDirectory(prefix='mhc_protocol_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE.parents[3],d/'compile.log');text=execute(['vvp',d/'a.vvp'],HERE.parents[3],d/'sim.log');assert 'PASS malvar protocol' in text;print(text.strip())
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),abort_states=[1,2,3,4,5,6],marker_errors=2,healthy_recovery_frames=9,healthy_pixels=135,reset_ce_disabled=True),indent=2)+'\n')
if __name__=='__main__':main()
