"""Atomic map commits, concurrent inactive loading, incomplete/error retention and frame recovery."""
import tempfile,json
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,map_begin_valid=0,map_valid=0,map_last=0,map_commit_valid=0,map_abort=0,map_done_ready=0;
reg start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg signed[23:0]map_x=0,map_y=0;reg[7:0]cfg_fill=73,s_data=0;
wire map_begin_ready,map_ready,map_commit_ready,map_done_valid,map_done_error,map_active_valid,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_in_bounds,done_valid,done_error,busy;
wire[7:0]map_error_code,error_code,m_data;
stereo_rectify #(.SRC_WIDTH(4),.SRC_HEIGHT(3),.DST_WIDTH(4),.DST_HEIGHT(3)) dut(.*);
integer cyc=0,got=0,mode=0,i,j;reg[11:0]held;reg stalled=0;
wire[11:0]token={m_last,m_eol,m_sof,m_in_bounds,m_data};
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%7<4;if(cyc>100000)$fatal(1,"timeout %d %d",dut.state,dut.map_state);end
always @(posedge clk)if(rst_n)begin
 if(!abort&&stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=!abort&&m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(!m_in_bounds||m_data!==8'd17*((mode==0)?(got%12):(11-got%12)))$fatal(1,"atomic pixel %d %d mode %d",got,m_data,mode);
 if(m_sof!==(got%12==0)||m_eol!==(got%4==3)||m_last!==(got%12==11))$fatal(1,"markers");got=got+1;end
end
 task tick;begin @(negedge clk);#1;end endtask
 task beginmap;begin map_begin_valid=1;while(!map_begin_ready)tick;@(posedge clk);#1;tick;map_begin_valid=0;end endtask
 task mapentries;input integer count,reverse,lastmode;integer k;begin
 for(k=0;k<count;k=k+1)begin map_x=((reverse?11-k:k)%4)*256;map_y=((reverse?11-k:k)/4)*256;map_last=(lastmode==1)?k==11:(lastmode==2)?k==0:0;map_valid=1;while(!map_ready)tick;@(posedge clk);#1;tick;end
 map_valid=0;map_last=0;end endtask
 task commitmap;begin map_commit_valid=1;while(!map_commit_ready)tick;@(posedge clk);#1;tick;map_commit_valid=0;end endtask
 task ackmap;input integer err,code;begin
 if(!map_done_valid||map_done_error!==err[0]||(err&&map_error_code!=code))$fatal(1,"map done %h",map_error_code);
 repeat(4)tick;map_done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;map_done_ready=0;end endtask
 task startframe;begin start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;end endtask
 task sendframe;integer k;begin
 for(k=0;k<12;k=k+1)begin s_data=k*17;s_sof=k==0;s_eol=k%4==3;s_last=k==11;s_valid=1;while(!s_ready)tick;@(posedge clk);#1;tick;end s_valid=0;end endtask
 task ackframe;input integer err,code;begin
 while(!done_valid)tick;if(done_error!==err[0]||(err&&error_code!=code))$fatal(1,"frame done %h",error_code);
 repeat(4)tick;done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;end endtask
 task healthy;input integer expect_count;begin startframe;sendframe;ackframe(0,0);if(got!=expect_count)$fatal(1,"count %d wanted %d",got,expect_count);end endtask
 initial begin
 repeat(3)tick;rst_n=1;tick;
 startframe;ackframe(1,8'h82);
 beginmap;mapentries(5,0,0);commitmap;ackmap(1,8'h82);if(map_active_valid)$fatal(1,"incomplete published");
 beginmap;mapentries(1,0,2);ackmap(1,8'h81);
 beginmap;mapentries(12,0,1);commitmap;ackmap(0,0);
 startframe;
 fork
 begin sendframe;end
 begin beginmap;mapentries(12,1,1);map_commit_valid=1;end
 join
 while(!done_valid)begin if(map_commit_ready)$fatal(1,"commit during busy");tick;end
 repeat(3)begin if(map_commit_ready)$fatal(1,"commit during done");tick;end
 ackframe(0,0);if(got!=12)$fatal(1,"old map changed during frame");
 while(!map_done_valid)tick;map_commit_valid=0;ackmap(0,0);mode=1;
 healthy(24);
 beginmap;mapentries(4,0,0);commitmap;ackmap(1,8'h82);if(!map_active_valid)$fatal(1,"old map lost");healthy(36);
 beginmap;mapentries(3,0,0);map_abort=1;while(!ce)tick;@(posedge clk);#1;tick;map_abort=0;ackmap(1,8'h93);healthy(48);
 // Malformed source terminates immediately; no need to send the remaining frame.
 startframe;s_data=99;s_valid=1;s_sof=0;s_eol=0;s_last=0;while(!s_ready)tick;@(posedge clk);#1;tick;s_valid=0;ackframe(1,8'h81);healthy(60);
 startframe;abort=1;while(!ce)tick;@(posedge clk);#1;tick;abort=0;ackframe(1,8'h93);healthy(72);
 // Abort held first output, including backpressure, then recover.
 startframe;force m_ready=0;sendframe;while(!m_valid)tick;abort=1;while(!ce)tick;@(posedge clk);#1;tick;abort=0;release m_ready;ackframe(1,8'h93);healthy(84);
 // Reset overrides CE and invalidates maps; reload is required after reset.
 startframe;force ce=0;rst_n=0;@(posedge clk);#1;if(busy||done_valid||map_active_valid)$fatal(1,"reset");tick;rst_n=1;release ce;got=0;mode=0;stalled=0;tick;
 startframe;ackframe(1,8'h82);beginmap;mapentries(12,0,1);commitmap;ackmap(0,0);healthy(12);
 $display("PASS stereo_rectify protocol");$finish;end
endmodule
'''
def main():
 with tempfile.TemporaryDirectory(prefix='stereo_rectify_protocol_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE.parents[3],d/'compile.log');text=execute(['vvp',d/'a.vvp'],HERE.parents[3],d/'sim.log');assert 'PASS stereo_rectify protocol' in text;print(text.strip())
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),atomic_during_busy=True,incomplete_commit_retains_active=True,map_abort_retains_active=True,marker_termination=True,reset_ce_disabled=True,healthy_frames=8,healthy_pixels=96),indent=2)+'\n')
if __name__=='__main__':main()
