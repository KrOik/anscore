import tempfile,json,hashlib
from pathlib import Path
from run_tests import HERE,execute
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_edge=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[7:0]cfg_theta=90;reg signed[7:0]cfg_rho=3;reg[1:0]cfg_rho_tolerance=0;
 reg[5:0]cfg_max_gap=0,cfg_min_length=3,cfg_min_support=2,cfg_max_segments=32;
 wire start_ready,s_ready,m_valid,done_valid,done_error,busy;wire[3:0]error_code;
 wire[5:0]m_x1,m_y1,m_x2,m_y2,m_support,m_index;wire[11:0]m_length_squared;
 hough_segments #(.WIDTH(8),.HEIGHT(8))dut(.*);
 integer i,n=0,phase,cy=0,healthy_count=0;reg checking=0;
 always @(posedge clk)begin cy=cy+1;if(cy>2000000)$fatal(1,"watchdog %d",dut.state);
 if(rst_n&&ce&&m_valid&&m_ready&&checking)begin
 if(n!=0||m_index!=0||m_x1!=1||m_y1!=3||m_x2!=6||m_y2!=3||m_support!=6||m_length_squared!=25)$fatal(1,"healthy endpoints");n=n+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;begin tick;rst_n=0;ce=0;start_valid=0;s_valid=0;m_ready=0;done_ready=0;checking=0;tick;
 if(m_valid||done_valid||busy||s_ready||start_ready)$fatal(1,"reset CE0");rst_n=1;ce=1;tick;end endtask
 task config_ok;begin cfg_theta=90;cfg_rho=3;cfg_rho_tolerance=0;cfg_max_gap=0;cfg_min_length=3;cfg_min_support=2;cfg_max_segments=32;end endtask
 task start;begin while(!start_ready)tick;start_valid=1;tick;start_valid=0;end endtask
 task feed;input integer bad;begin while(!s_ready)tick;
 for(i=0;i<64;i=i+1)begin s_edge=i/8==3&&i%8>=1&&i%8<=6;s_sof=i==0;s_eol=i%8==7;s_last=i==63;
 case(bad)0:if(i==0)s_sof=0;1:if(i==1)s_sof=1;2:if(i==7)s_eol=0;3:if(i==2)s_eol=1;4:if(i==63)s_last=0;5:if(i==2)s_last=1;endcase
 s_valid=1;while(!s_ready)tick;tick;s_valid=0;end end endtask
 task ack;begin done_ready=1;tick;done_ready=0;tick;end endtask
 task healthy;begin config_ok;checking=1;n=0;m_ready=1;start;feed(-1);while(!done_valid)tick;
 if(done_error||error_code||n!=1)$fatal(1,"healthy completion");checking=0;m_ready=0;ack;healthy_count=healthy_count+1;end endtask
 task error_result;input[3:0]code;begin while(!done_valid)tick;
 if(!done_error||error_code!=code||m_valid||m_x1||m_x2||m_y1||m_y2||m_support||m_index||m_length_squared)$fatal(1,"error metadata");
 repeat(3)begin tick;if(!done_valid||error_code!=code)$fatal(1,"error hold");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE ACK");ce=1;tick;done_ready=0;end endtask
 initial begin reset;healthy;
 for(phase=0;phase<6;phase=phase+1)begin config_ok;start;feed(phase);error_result(2);healthy;end
 for(phase=0;phase<10;phase=phase+1)begin config_ok;
 case(phase)0:cfg_theta=180;1:cfg_rho=-46;2:cfg_rho=46;3:cfg_max_gap=32;4:cfg_min_length=0;5:cfg_min_length=45;6:cfg_min_support=1;7:cfg_min_support=33;8:cfg_max_segments=0;9:cfg_max_segments=33;endcase
 start;error_result(1);healthy;end
 for(phase=0;phase<12;phase=phase+1)begin config_ok;start;if(phase>1)feed(-1);
 case(phase)
 0:while(dut.state!=17)tick;1:while(dut.state!=1)tick;2:while(dut.state!=3)tick;
 3:while(dut.state!=5)tick;4:while(dut.state!=17||dut.return_state!=7)tick;
 5:while(dut.state!=17||dut.return_state!=8)tick;6:while(dut.state!=9)tick;
 7:while(dut.state!=17||dut.return_state!=12)tick;8:while(dut.state!=17||dut.return_state!=13)tick;
 9:while(dut.state!=14)tick;10:while(!m_valid)tick;
 11:begin m_ready=1;while(!done_valid)tick;m_ready=0;end
 endcase
 reset;healthy;end
 $display("PASS healthy=%d",healthy_count);$finish;end endmodule'''
with tempfile.TemporaryDirectory(prefix='segments_protocol_') as tmp:
 d=Path(tmp);(d/'tb.sv').write_text(tb);(d/'trig.mem').write_bytes((HERE/'trig.mem').read_bytes())
 execute(['iverilog','-g2012','-s','tb','-o',d/'sim',HERE/'hough_segments.sv',d/'tb.sv'],d,d/'compile.log')
 result=execute(['vvp',d/'sim'],d,d/'run.log');assert 'PASS healthy=         29' in result,result;print(result)
(HERE/'protocol_result.json').write_text(json.dumps(dict(status='PASS',healthy_recovery_frames=29,marker_errors=6,invalid_configs=10,reset_ce0_states=12,rtl_sha256=hashlib.sha256((HERE/'hough_segments.sv').read_bytes()).hexdigest()),indent=2)+'\n')
