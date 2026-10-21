"""Aborts every active state, marker faults, held DONE and CE-disabled reset."""
from pathlib import Path
import tempfile,json
from run_tests import HERE,RTL,execute,hashes
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,cfg_auto=1,abort=0;
reg[1:0]cfg_pattern=0;reg[31:0]cfg_black_levels=0;reg[7:0]cfg_target_pedestal=20;
reg[15:0]cfg_roi_x=0,cfg_roi_y=0,cfg_roi_width=4,cfg_roi_height=4;
reg[7:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;
wire[127:0]stats_sums,stats_counts;wire[31:0]stats_mean_levels,applied_black_levels,clip_low_count,clip_high_count;
raw_black_level #(.WIDTH(4),.HEIGHT(4),.BITS(8))dut(.*);
integer cyc=0,i,j,got=0,healthy_frames=0,p,expected;reg healthy=0,pause_ce=0,stalled=0;reg[10:0]held;
wire[10:0]token={m_last,m_eol,m_sof,m_data};
task tick;begin @(negedge clk);#1;end endtask
always @(negedge clk)begin cyc=cyc+1;ce=!pause_ce&&cyc%11>1;if(cyc>200000)$fatal(1,"timeout %d",dut.state);end
always @(posedge clk)begin
if(!rst_n||abort)stalled=0;
else begin
if(stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=m_valid&&!(ce&&m_ready);held=token;
if(ce&&m_valid&&m_ready&&healthy)begin
p=((got/4)%2)*2+got%2;
case(p)0:expected=got-5+20;1:expected=got-6+20;2:expected=got-9+20;3:expected=got-10+20;endcase
if(m_data!==expected||m_sof!==(got==0)||m_eol!==(got%4==3)||m_last!==(got==15))$fatal(1,"healthy pixel %d %d %d",got,m_data,expected);
got=got+1;end end end
task start;begin m_ready=0;start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;end endtask
task send;input integer bad;begin
for(i=0;i<16;i=i+1)begin
s_data=i;s_valid=1;s_sof=i==0;s_eol=i%4==3;s_last=i==15;
if(bad==0&&i==0)s_sof=0;
if(bad==1&&i==2)s_sof=1;
if(bad==2&&i==3)s_eol=0;
if(bad==3&&i==15)s_last=0;
while(!s_ready)tick;@(posedge clk);#1;tick;
if(done_valid)i=16;
end s_valid=0;end endtask
task ack;input[7:0]code;begin
while(!done_valid)tick;
if(done_error!==(code!=0)||error_code!==code)$fatal(1,"done %h vs %h",error_code,code);
pause_ce=1;abort=1;repeat(4)tick;if(!done_valid||error_code!==code)$fatal(1,"late abort done");abort=0;pause_ce=0;
repeat(5)tick;if(!done_valid||error_code!==code)$fatal(1,"done hold");
done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;
end endtask
task recovery;begin
got=0;healthy=1;start;send(-1);m_ready=1;ack(0);healthy=0;
if(got!=16||stats_sums!==128'h00000028000000240000001800000014||stats_counts!==128'h00000004000000040000000400000004||stats_mean_levels!==32'h0a090605||applied_black_levels!==32'h0a090605||clip_low_count||clip_high_count)$fatal(1,"recovery stats");
healthy_frames=healthy_frames+1;end endtask
initial begin repeat(3)tick;rst_n=1;tick;
for(j=1;j<=7;j=j+1)begin
 start;if(j!=1)send(-1);
 while(dut.state!=j)tick;
 // Abort blocks visible acceptance immediately, latches only on enabled clock.
 pause_ce=1;tick;abort=1;#1;if(m_valid||s_ready||start_ready)$fatal(1,"abort gate");repeat(3)tick;
 pause_ce=0;while(!ce)tick;@(posedge clk);#1;tick;abort=0;
 ack(8'h93);recovery;
end
for(j=0;j<4;j=j+1)begin start;send(j);ack(8'h81);recovery;end
start;send(-1);while(dut.state!=7)tick;
pause_ce=1;tick;rst_n=0;@(posedge clk);#1;if(done_valid||m_valid||busy)$fatal(1,"reset CE0");tick;rst_n=1;pause_ce=0;recovery;
$display("PASS raw_black_level protocol frames=%d",healthy_frames);$finish;end endmodule
'''
def main():
 frozen=hashes()
 with tempfile.TemporaryDirectory(prefix='raw_blc_protocol_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'compile.log')
  text=execute(['vvp',d/'a.vvp'],HERE,d/'sim.log');assert 'PASS raw_black_level protocol' in text;print(text.strip())
 assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,abort_states=list(range(1,8)),marker_errors=4,healthy_recovery_frames=12,healthy_pixels=192,reset_ce_disabled=True),indent=2)+'\n')
if __name__=='__main__':main()
