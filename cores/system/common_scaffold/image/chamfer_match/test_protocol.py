import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes,oracle,np
image=np.zeros((4,5),bool);image[1,1]=1;image[2,2]=1
template=np.eye(2,dtype=bool);_,expected,best,_=oracle(image,template)
checks='\n'.join(f'{i}:if(m_x!={x}||m_y!={y}||m_score!={score}||m_sum_squared!={total}||m_invalid)$fatal(1,"healthy map");' for i,(x,y,score,total,inv) in enumerate(expected))
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,t_valid=0,t_edge=0,t_sof=0,t_eol=0,t_last=0,s_valid=0,s_edge=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[3:0]cfg_template_width=2,cfg_template_height=2;
 wire start_ready,t_ready,s_ready,m_valid,m_invalid,m_sof,m_eol,m_last,done_valid,done_error,busy,best_valid;
 wire[31:0]m_score,m_sum_squared,best_score,best_sum_squared;wire[5:0]m_x,m_y,best_x,best_y;wire[6:0]template_edges;wire[3:0]error_code;
 chamfer_match #(.WIDTH(5),.HEIGHT(4))dut(.*);
 integer i,n=0,phase,cy=0,healthy_count=0;reg checking=0;
 always @(posedge clk)begin cy=cy+1;if(cy>1500000)$fatal(1,"watchdog %d edt%0d phase%0d",dut.state,dut.edt.state,phase);
 if(rst_n&&ce&&m_valid&&m_ready)begin
 if(checking)begin case(n) CHECKS default:$fatal(1,"extra score");endcase end n=n+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;begin tick;rst_n=0;ce=0;start_valid=0;t_valid=0;s_valid=0;m_ready=0;done_ready=0;checking=0;
 repeat(3)tick;if(m_valid||done_valid||busy||t_ready||s_ready||start_ready)$fatal(1,"CE0 reset");rst_n=1;ce=1;tick;end endtask
 task config_ok;begin cfg_template_width=2;cfg_template_height=2;end endtask
 task start;begin while(!start_ready)tick;n=0;start_valid=1;tick;start_valid=0;end endtask
 task feed_template;input integer bad;begin for(i=0;i<4;i=i+1)begin
 t_edge=i==0||i==3;t_sof=i==0;t_eol=i%2==1;t_last=i==3;
 case(bad)0:if(i==0)t_sof=0;1:if(i==1)t_sof=1;2:if(i==1)t_eol=0;3:if(i==0)t_eol=1;4:if(i==3)t_last=0;5:if(i==0)t_last=1;endcase
 t_valid=1;while(!t_ready)tick;tick;t_valid=0;end end endtask
 task feed_frame;input integer bad;begin for(i=0;i<20;i=i+1)begin
 s_edge=i==6||i==12;s_sof=i==0;s_eol=i%5==4;s_last=i==19;
 case(bad)0:if(i==0)s_sof=0;1:if(i==1)s_sof=1;2:if(i==4)s_eol=0;3:if(i==0)s_eol=1;4:if(i==19)s_last=0;5:if(i==0)s_last=1;endcase
 s_valid=1;while(!s_ready)tick;tick;s_valid=0;end end endtask
 task ack;begin done_ready=1;tick;done_ready=0;tick;end endtask
 task good_done;begin while(!done_valid)tick;
 if(done_error||error_code||n!=12||!best_valid||best_x!=1||best_y!=1||best_score||best_sum_squared||template_edges!=2)$fatal(1,"healthy DONE");
 checking=0;m_ready=0;ack;healthy_count=healthy_count+1;end endtask
 task healthy;begin config_ok;checking=1;m_ready=1;start;feed_template(-1);feed_frame(-1);good_done;end endtask
 task error_result;input[3:0]code;begin while(!done_valid)tick;
 if(!done_error||error_code!=code||m_valid||n||best_valid||best_x||best_y||best_score||best_sum_squared||m_score||m_sum_squared)$fatal(1,"error metadata");
 repeat(3)begin tick;if(!done_valid||error_code!=code)$fatal(1,"held error");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE ACK");ce=1;tick;done_ready=0;end endtask
 initial begin reset;healthy;
 for(phase=0;phase<6;phase=phase+1)begin config_ok;start;feed_template(phase);error_result(2);healthy;end
 for(phase=0;phase<6;phase=phase+1)begin config_ok;start;feed_template(-1);feed_frame(phase);error_result(3);healthy;end
 for(phase=0;phase<6;phase=phase+1)begin config_ok;
 case(phase)0:cfg_template_width=0;1:cfg_template_height=0;2:cfg_template_width=9;3:cfg_template_height=9;4:cfg_template_width=6;5:cfg_template_height=5;endcase
 start;error_result(1);if(template_edges)$fatal(1,"invalid config stale count");healthy;end
 config_ok;start;feed_template(-1);dut.edt.state=15;tick;error_result(4);healthy;
 config_ok;start;dut.state=15;tick;error_result(5);healthy;
 for(phase=0;phase<17;phase=phase+1)begin config_ok;start;if(phase>0)feed_template(-1);if(phase>1)feed_frame(-1);
 case(phase)
 0:while(dut.state!=1)tick;1:while(dut.state!=2)tick;
 2:while(dut.edt.state!=1)tick;3:while(dut.edt.state!=2)tick;4:while(dut.edt.state!=3)tick;
 5:while(dut.edt.state!=5)tick;6:while(dut.edt.state!=6)tick;7:while(dut.edt.state!=7)tick;
 8:while(dut.edt.state!=8)tick;9:while(dut.edt.state!=9)tick;
 10:while(dut.state!=5)tick;11:while(dut.state!=6)tick;12:while(dut.state!=7)tick;
 13:while(dut.state!=9)tick;14:while(dut.state!=10)tick;15:while(!m_valid)tick;
 16:begin m_ready=1;while(!done_valid)tick;m_ready=0;end
 endcase
 reset;healthy;end
 // Artificial final EDT value and DONE on the same rising edge.
 config_ok;checking=1;m_ready=1;start;feed_template(-1);feed_frame(-1);
 while(dut.distance_count!=19||!dut.dt_valid)tick;force dut.dt_done=1;tick;release dut.dt_done;good_done;
 $display("PASS healthy=%d",healthy_count);$finish;end endmodule'''
tb=tb.replace('CHECKS',checks);frozen=hashes()
with tempfile.TemporaryDirectory(prefix='chamfer_protocol_') as tmp:
 d=Path(tmp);(d/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log')
 result=execute(['vvp',d/'sim'],d,d/'run.log',timeout=180);assert 'PASS healthy=         39' in result,result;print(result)
assert frozen==hashes()
(HERE/'protocol_result.json').write_text(json.dumps(dict(status='PASS',healthy_recovery_frames=39,template_marker_errors=6,frame_marker_errors=6,invalid_configs=6,child_internal_errors=2,reset_ce0_phases=17,final_edt_value_and_done_same_cycle=True,sources=frozen),indent=2)+'\n')
