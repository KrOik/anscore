import tempfile,json,hashlib
from pathlib import Path
from run_tests import HERE,oracle,execute,np
im=np.eye(8,dtype=bool);expected=oracle(im,4,2,2,1,5)
checks='\n'.join(f'{i}:if(m_theta!={t}||$signed(m_rho)!={r}||m_score!={s})$fatal(1,"recovery peak");' for i,(t,r,s) in enumerate(expected))
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_edge=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[10:0]cfg_threshold=4;reg[4:0]cfg_max_lines=2;reg[6:0]cfg_theta_nms=2,cfg_rho_nms=1;
 wire start_ready,s_ready,m_valid,done_valid,done_error,busy;wire[7:0]m_theta;wire signed[7:0]m_rho;wire[10:0]m_score;wire[4:0]m_index;wire[3:0]error_code;
 hough_lines_full #(.WIDTH(8),.HEIGHT(8),.THETA_STEP(5))dut(.*);
 integer n=0,i,phase,cy=0,healthy_count=0;reg check_outputs=0;
 always @(posedge clk)begin
  cy=cy+1;if(cy>14000000)$fatal(1,"watchdog %d",dut.state);
  if(rst_n&&ce&&m_valid&&m_ready&&check_outputs)begin case(n) CHECKS default:$fatal(1,"extra");endcase n=n+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;begin tick;rst_n=0;ce=0;s_valid=0;start_valid=0;m_ready=0;done_ready=0;check_outputs=0;tick;
 if(m_valid||done_valid||busy||s_ready||start_ready)$fatal(1,"reset ce0");rst_n=1;ce=1;tick;end endtask
 task config_ok;begin cfg_threshold=4;cfg_max_lines=2;cfg_theta_nms=2;cfg_rho_nms=1;end endtask
 task start;begin while(!start_ready)tick;start_valid=1;tick;start_valid=0;end endtask
 task feed;input integer bad;begin for(i=0;i<64;i=i+1)begin
 s_edge=i%9==0;s_sof=i==0;s_eol=i%8==7;s_last=i==63;
 case(bad)0:if(i==0)s_sof=0;1:if(i==1)s_sof=1;2:if(i==7)s_eol=0;3:if(i==2)s_eol=1;4:if(i==63)s_last=0;5:if(i==2)s_last=1;endcase
 s_valid=1;while(!s_ready)tick;tick;s_valid=0;end end endtask
 task ack;begin done_ready=1;tick;done_ready=0;tick;end endtask
 task healthy;begin config_ok;n=0;check_outputs=1;m_ready=1;start;feed(-1);while(!done_valid)tick;
 if(done_error||error_code||n!=COUNT)$fatal(1,"healthy");check_outputs=0;m_ready=0;ack;healthy_count=healthy_count+1;end endtask
 task check_error;input[3:0]code;begin while(!done_valid)tick;
 if(!done_error||error_code!=code||m_valid||m_score||m_theta||m_rho||m_index)$fatal(1,"error metadata %d",code);
 repeat(3)begin tick;if(!done_valid||error_code!=code)$fatal(1,"held error");end
 ce=0;done_ready=1;repeat(2)tick;if(!done_valid)$fatal(1,"error ce0 ack");ce=1;tick;done_ready=0;end endtask
 initial begin reset;healthy;
 for(phase=0;phase<6;phase=phase+1)begin config_ok;start;feed(phase);check_error(2);healthy;end
 for(phase=0;phase<6;phase=phase+1)begin config_ok;
 case(phase)0:cfg_threshold=0;1:cfg_threshold=1025;2:cfg_max_lines=0;3:cfg_max_lines=17;4:cfg_theta_nms=91;5:cfg_rho_nms=91;endcase
 start;check_error(1);healthy;end
 for(phase=0;phase<10;phase=phase+1)begin config_ok;start;if(phase!=0)feed(-1);
 case(phase)
 0:while(dut.state!=1)tick;1:while(dut.state!=2)tick;2:while(dut.state!=8)tick;
 3:while(dut.state!=9)tick;4:while(dut.state!=13)tick;5:while(dut.state!=18)tick;
 6:while(!m_valid)tick;7:begin m_ready=1;while(dut.state!=23)tick;m_ready=0;end
 8:while(dut.state!=7)tick;9:begin m_ready=1;while(!done_valid)tick;m_ready=0;end
 endcase
 reset;healthy;
 end
 $display("PASS healthy=%d",healthy_count);$finish;end endmodule'''
tb=tb.replace('CHECKS',checks).replace('COUNT',str(len(expected)))
with tempfile.TemporaryDirectory(prefix='full_hough_protocol_') as temp:
 d=Path(temp);(d/'trig.mem').write_bytes((HERE/'trig.mem').read_bytes());(d/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',d/'sim',HERE/'hough_lines_full.sv',d/'tb.sv'],d,d/'compile.log')
 result=execute(['vvp',d/'sim'],d,d/'run.log',timeout=300);assert 'PASS healthy=         23' in result,result;print(result)
(HERE/'protocol_result.json').write_text(json.dumps(dict(status='PASS',healthy_recovery_frames=23,marker_errors=6,invalid_configs=6,reset_ce0_states=10,rtl_sha256=hashlib.sha256((HERE/'hough_lines_full.sv').read_bytes()).hexdigest()),indent=2)+'\n')
