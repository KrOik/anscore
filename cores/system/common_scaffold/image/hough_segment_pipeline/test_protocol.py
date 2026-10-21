import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_edge=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[10:0]cfg_threshold=6;reg[4:0]cfg_max_candidates=2;reg[6:0]cfg_theta_nms=0,cfg_rho_nms=0;
 reg[1:0]cfg_rho_tolerance=0;reg[5:0]cfg_max_gap=0,cfg_min_length=3,cfg_min_support=2,cfg_max_segments=32;
 wire start_ready,s_ready,m_valid,done_valid,done_error,busy;wire[7:0]error_code,m_theta;wire signed[7:0]m_rho;
 wire[5:0]m_x1,m_y1,m_x2,m_y2,m_support,m_segment_index;wire[11:0]m_length_squared;wire[4:0]m_candidate_index,detected_candidates;wire[9:0]emitted_segments;
 hough_segment_pipeline #(.WIDTH(8),.HEIGHT(8),.THETA_STEP(30))dut(.*);
 integer i,n=0,phase,cy=0,healthy_count=0;reg checking=0;
 always @(posedge clk)begin
 cy=cy+1;if(cy>6000000)$fatal(1,"watchdog top=%d polar=%d seg=%d phase=%d",dut.state,dut.polar.state,dut.segments.state,phase);
 if(ce&&((dut.seg_valid&&dut.segments.m_ready)!=(m_valid&&m_ready)))$fatal(1,"transfer mismatch");
 if(rst_n&&ce&&m_valid&&m_ready)begin
  if(checking)begin
   if(m_candidate_index!=n||m_segment_index||m_support!=8||m_length_squared!=49)$fatal(1,"healthy metadata");
   if(n==0)begin if(m_theta!=0||m_rho!=2||m_x1!=2||m_y1!=0||m_x2!=2||m_y2!=7)$fatal(1,"healthy vertical");end
   else if(n==1)begin if(m_theta!=90||m_rho!=4||m_x1!=0||m_y1!=4||m_x2!=7||m_y2!=4)$fatal(1,"healthy horizontal");end
   else $fatal(1,"extra token");
  end
  n=n+1;
 end end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;begin tick;rst_n=0;ce=0;start_valid=0;s_valid=0;m_ready=0;done_ready=0;checking=0;
 repeat(3)tick;if(m_valid||done_valid||busy||s_ready||start_ready)$fatal(1,"CE0 reset");rst_n=1;ce=1;tick;end endtask
 task config_ok;begin cfg_threshold=6;cfg_max_candidates=2;cfg_theta_nms=0;cfg_rho_nms=0;cfg_rho_tolerance=0;cfg_max_gap=0;cfg_min_length=3;cfg_min_support=2;cfg_max_segments=32;end endtask
 task start;begin while(!start_ready)tick;n=0;start_valid=1;tick;start_valid=0;end endtask
 task feed;input integer bad;begin
 for(i=0;i<64;i=i+1)begin s_edge=i%8==2||i/8==4;s_sof=i==0;s_eol=i%8==7;s_last=i==63;
 case(bad)0:if(i==0)s_sof=0;1:if(i==1)s_sof=1;2:if(i==7)s_eol=0;3:if(i==2)s_eol=1;4:if(i==63)s_last=0;5:if(i==2)s_last=1;endcase
 s_valid=1;while(!s_ready)tick;tick;s_valid=0;end end endtask
 task ack;begin done_ready=1;tick;done_ready=0;tick;end endtask
 task healthy;begin config_ok;checking=1;m_ready=1;start;feed(-1);while(!done_valid)tick;
 if(done_error||error_code||n!=2||emitted_segments!=2||detected_candidates!=2)$fatal(1,"healthy completion");checking=0;m_ready=0;ack;healthy_count=healthy_count+1;end endtask
 task error_result;input[7:0]code;begin while(!done_valid)tick;
 if(!done_error||error_code!=code||m_valid||emitted_segments!=n||m_theta||m_rho||m_x1||m_y1||m_x2||m_y2||m_support)$fatal(1,"error code/count got=%h n=%d count=%d",error_code,n,emitted_segments);
 if(code==1&&(detected_candidates||emitted_segments))$fatal(1,"invalid cfg stale metadata");
 repeat(3)begin tick;if(!done_valid||error_code!=code)$fatal(1,"held error");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE ACK");ce=1;tick;done_ready=0;end endtask
 initial begin reset;healthy;
 for(phase=0;phase<6;phase=phase+1)begin config_ok;start;feed(phase);error_result(8'h12);healthy;end
 for(phase=0;phase<13;phase=phase+1)begin config_ok;
 case(phase)0:cfg_threshold=0;1:cfg_threshold=1025;2:cfg_max_candidates=0;3:cfg_max_candidates=17;
 4:cfg_theta_nms=91;5:cfg_rho_nms=91;6:cfg_max_gap=32;7:cfg_min_length=0;8:cfg_min_length=45;
 9:cfg_min_support=1;10:cfg_min_support=33;11:cfg_max_segments=0;12:cfg_max_segments=33;endcase
 start;error_result(1);healthy;end
 // Error in polar during capture must terminate rather than deadlock s_ready.
 config_ok;start;dut.polar.state=31;tick;error_result(8'h14);healthy;
 // Segmentation child error during replay, before any segment output.
 config_ok;start;feed(-1);while(dut.state!=8)tick;dut.segments.state=31;tick;error_result(8'h24);healthy;
 // At an output edge, count exactly what external valid/ready accepts.
 config_ok;start;feed(-1);while(!m_valid)tick;m_ready=1;dut.segments.state=31;tick;m_ready=0;error_result(8'h24);if(n!=1)$fatal(1,"error edge prefix accounting");healthy;
 // A later candidate error preserves the already accepted prefix count.
 config_ok;start;m_ready=1;feed(-1);while(dut.candidate_index!=1||dut.state!=8)tick;m_ready=0;dut.segments.state=31;tick;error_result(8'h24);if(n!=1)$fatal(1,"second candidate prefix");healthy;
 config_ok;start;dut.state=14;tick;error_result(8'h40);healthy;
 // Deliberate impossible candidate overflow tests explicit containment.
 config_ok;start;feed(-1);while(dut.state!=2)tick;dut.detected_candidates=16;force dut.full_valid=1;tick;release dut.full_valid;error_result(8'h30);healthy;
 for(phase=0;phase<12;phase=phase+1)begin config_ok;start;if(phase>0)feed(-1);
 case(phase)
 0:while(dut.state!=1)tick;1:while(dut.polar.state!=8)tick;2:while(dut.polar.state!=20)tick;
 3:while(dut.state!=4)tick;4:while(dut.state!=6)tick;5:while(dut.state!=8)tick;
 6:while(dut.state!=10)tick;7:while(dut.state!=11||dut.segments.state!=17)tick;
 8:while(!m_valid)tick;9:begin m_ready=1;while(dut.candidate_index!=1||dut.state!=8)tick;m_ready=0;end
 10:begin m_ready=1;while(!done_valid)tick;m_ready=0;end
 11:while(dut.polar.state!=2)tick;
 endcase
 reset;healthy;end
 // Artificial coincident final peak and DONE: top must include the final peak.
 config_ok;start;feed(-1);while(dut.state!=2)tick;
 force dut.full_valid=1;force dut.full_done=1;force dut.full_theta=90;force dut.full_rho=4;
 tick;release dut.full_valid;release dut.full_done;release dut.full_theta;release dut.full_rho;
 m_ready=1;while(!done_valid)tick;if(done_error||detected_candidates!=1||n!=1||emitted_segments!=1)$fatal(1,"last peak + done");reset;healthy;
 // Artificial coincident final segment and DONE: external token and count agree.
 config_ok;start;feed(-1);m_ready=1;while(dut.candidate_index!=1||!m_valid)tick;
 force dut.seg_done=1;tick;release dut.seg_done;m_ready=0;
 if(!done_valid||done_error||n!=2||emitted_segments!=2)$fatal(1,"last segment + done");reset;healthy;
 $display("PASS healthy=%d",healthy_count);$finish;end endmodule'''
frozen=hashes()
with tempfile.TemporaryDirectory(prefix='hough_pipeline_protocol_') as tmp:
 d=Path(tmp);(d/'tb.sv').write_text(tb);(d/'trig.mem').write_bytes((HERE/'trig.mem').read_bytes())
 execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log')
 result=execute(['vvp',d/'sim'],d,d/'run.log',timeout=300);assert 'PASS healthy=         40' in result,result;print(result)
assert frozen==hashes()
(HERE/'protocol_result.json').write_text(json.dumps(dict(status='PASS',healthy_recovery_frames=40,marker_errors=6,invalid_configs=13,reset_ce0_phases=12,child_and_internal_errors=6,coincident_completion_boundaries=2,exact_internal_external_handshakes=True,sources=frozen),indent=2)+'\n')
