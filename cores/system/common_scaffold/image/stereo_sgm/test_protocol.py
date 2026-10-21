import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,s_left_border=0,s_right_border=0,m_ready=0,done_ready=0;
reg[7:0]cfg_p1=2,cfg_p2=8;reg[7:0]s_left=0,s_right=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,m_invalid;wire[2:0]error_code;wire[1:0]m_disparity;wire[13:0]m_score;
stereo_sgm #(.WIDTH(4),.HEIGHT(3),.DESC_BITS(8),.DISPARITIES(4))dut(.*);
integer i,cy=0,n=0;
always @(posedge clk)begin cy=cy+1;if(cy>100000)$fatal(1,"timeout");if(ce&&m_valid&&m_ready)n=n+1;end
 task tick;begin @(negedge clk);#1;end endtask
 task launch;begin start_valid=1;tick;start_valid=0;end endtask
 task ack;begin if(!done_valid)$fatal(1,"missing done");ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"ce ack");ce=1;tick;done_ready=0;if(!start_ready)$fatal(1,"not idle");end endtask
 task feed;begin for(i=0;i<12;i=i+1)begin s_valid=1;s_sof=i==0;s_eol=i%4==3;s_last=i==11;tick;end s_valid=0;end endtask
 initial begin repeat(2)tick;rst_n=1;tick;
 cfg_p1=9;cfg_p2=8;launch;if(!done_valid||!done_error||error_code!=1)$fatal(1,"config");ack;cfg_p1=2;
 launch;s_valid=1;s_sof=0;tick;s_valid=0;if(!done_error||error_code!=2)$fatal(1,"sof");ack;
 launch;s_valid=1;s_sof=1;s_eol=1;tick;s_valid=0;if(!done_error||error_code!=2)$fatal(1,"eol");ack;
 launch;s_valid=1;s_sof=1;s_eol=0;s_last=1;tick;s_valid=0;if(!done_error||error_code!=2)$fatal(1,"last");ack;s_last=0;
 // Reset from capture, traversal, output stall, and terminal done.
 launch;repeat(2)tick;rst_n=0;tick;rst_n=1;tick;if(!start_ready||m_valid||done_valid)$fatal(1,"reset capture");
 launch;feed;repeat(30)tick;ce=0;repeat(5)tick;rst_n=0;tick;rst_n=1;ce=1;tick;if(!start_ready)$fatal(1,"reset traverse");
 launch;feed;while(!m_valid)tick;repeat(4)tick;rst_n=0;tick;rst_n=1;tick;if(m_valid||!start_ready)$fatal(1,"reset hold");
 // Two complete frames without reset; old RAM contents must not leak.
 repeat(2)begin n=0;launch;feed;m_ready=1;while(!done_valid)tick;m_ready=0;if(n!=12||done_error)$fatal(1,"recover frame");ack;end
 rst_n=0;tick;rst_n=1;tick;if(!start_ready)$fatal(1,"reset done");
 $display("PASS malformed=4 resets=4 recovered_frames=2");$finish;end endmodule'''
frozen=hashes()
with tempfile.TemporaryDirectory(prefix='sgm_protocol_') as tmp:
 p=Path(tmp);(p/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');text=execute(['vvp',p/'sim'],p,p/'sim.log');assert 'PASS' in text;print(text)
assert hashes()==frozen
(HERE/'protocol_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,malformed=4,resets=4,recovered_frames=2,simulation=text.strip()),indent=2)+'\n')
