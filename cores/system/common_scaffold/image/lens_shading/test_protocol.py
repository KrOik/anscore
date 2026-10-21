import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cfg_valid=0,cfg_commit_valid=0,start_valid=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=1,done_ready=0;
reg[15:0]cfg_index;reg[7:0]cfg_gain;reg[1:0]cfg_pattern=0;reg[7:0]s_data=10;
wire cfg_ready,cfg_commit_ready,cfg_error,cfg_pending,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_saturated,done_valid,done_error;wire[7:0]m_data;wire[2:0]error_code;
lens_shading #(.WIDTH(3),.HEIGHT(2),.BITS(8),.GRID_WIDTH(2),.GRID_HEIGHT(2),.GAIN_BITS(8),.GAIN_FRAC(4))dut(.*);
integer i,n=0,cy=0,mode=0,k;reg checking=0;
always @(posedge clk)begin
cy=cy+1;if(cy>100000)$fatal(1,"timeout state%d",dut.state);
if(rst_n&&ce&&m_valid&&m_ready&&checking)begin
if(m_saturated||m_sof!=(n==0)||m_eol!=(n%3==2)||m_last!=(n==5))$fatal(1,"markers");
if(mode==0&&m_data!=10)$fatal(1,"old map altered");
if(mode==1)begin case(n)0,2:if(m_data!=20)$fatal(1,"R");1:if(m_data!=30)$fatal(1,"Gr");3,5:if(m_data!=40)$fatal(1,"Gb");4:if(m_data!=50)$fatal(1,"B");endcase end
n=n+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 task loadmap;input newer;begin
 for(i=0;i<16;i=i+1)begin cfg_index=i;cfg_gain=newer?(i/4+2)*16:16;cfg_valid=1;tick;if(!cfg_ready)$fatal(1,"load ready");end cfg_valid=0;end endtask
 task commit;begin cfg_commit_valid=1;tick;cfg_commit_valid=0;#1;end endtask
 task launch;begin #1;if(!start_ready)$fatal(1,"not configured");start_valid=1;tick;start_valid=0;n=0;end endtask
 task beat;input integer idx;begin s_valid=1;s_data=10;s_sof=idx==0;s_eol=idx%3==2;s_last=idx==5;#1;while(!s_ready)tick;tick;s_valid=0;end endtask
 task finishframe;begin while(!done_valid)tick;if(done_error||error_code||n!=6)$fatal(1,"frame done %d",n);checking=0;ce=0;done_ready=1;repeat(2)tick;if(!done_valid)$fatal(1,"done CE");ce=1;tick;done_ready=0;tick;end endtask
 task healthy;input expectedmode;begin mode=expectedmode;launch;checking=1;for(k=0;k<6;k=k+1)beat(k);finishframe;end endtask
 task reset_core;begin checking=0;ce=0;rst_n=0;tick;if(m_valid||done_valid||start_ready||s_ready||cfg_ready||cfg_commit_ready)$fatal(1,"reset");rst_n=1;ce=1;tick;if(start_ready)$fatal(1,"stale configured");loadmap(0);commit;if(cfg_error||cfg_pending)$fatal(1,"reset config");end endtask
 initial begin repeat(2)tick;rst_n=1;tick;
 commit;if(!cfg_error||start_ready)$fatal(1,"incomplete initial commit");
 cfg_index=16;cfg_gain=16;cfg_valid=1;tick;cfg_valid=0;if(!cfg_error)$fatal(1,"index bounds");
 loadmap(0);commit;if(cfg_error||cfg_pending)$fatal(1,"initial commit");
 // Load and commit complete nonuniform next map during the first point of an active frame.
 mode=0;launch;checking=1;beat(0);loadmap(1);commit;if(cfg_error||!cfg_pending)$fatal(1,"pending commit");
 cfg_valid=1;cfg_gain=0;cfg_index=0;cfg_commit_valid=1;repeat(3)begin tick;if(cfg_ready||cfg_commit_ready)$fatal(1,"pending lock");end cfg_valid=0;cfg_commit_valid=0;
 for(k=1;k<6;k=k+1)beat(k);finishframe;if(cfg_pending)$fatal(1,"pending swap");healthy(1);
 // Rejected partial/duplicate map commits must preserve the current active table.
 cfg_valid=1;cfg_index=0;cfg_gain=0;repeat(16)tick;cfg_valid=0;commit;if(!cfg_error)$fatal(1,"duplicate completeness");healthy(1);
 // Source marker errors remain explicit, and valid recovery keeps active map.
 for(k=0;k<3;k=k+1)begin launch;s_valid=1;s_sof=k!=0;s_eol=k==1;s_last=k==2;tick;s_valid=0;if(!done_valid||!done_error||error_code!=1)$fatal(1,"marker error");done_ready=1;tick;done_ready=0;end
 healthy(1);
 launch;beat(0);while(!s_ready)tick;s_valid=1;s_sof=1;s_eol=0;s_last=0;tick;s_valid=0;
 if(!done_valid||!done_error||error_code!=1)$fatal(1,"midframe marker");done_ready=1;tick;done_ready=0;
 healthy(1);
 // Reset at input wait, multiply, divide, and output hold, then fresh map/frame recovery.
 launch;reset_core;healthy(0);
 launch;beat(0);while(dut.state!=4)tick;reset_core;healthy(0);
 launch;beat(0);while(dut.state!=9)tick;reset_core;healthy(0);
 m_ready=0;launch;beat(0);while(!m_valid)tick;reset_core;m_ready=1;healthy(0);
 $display("PASS config_errors=3 marker_errors=4 resets=4 healthy_frames=9 atomic_pending_swap");$finish;end endmodule'''
frozen=hashes()
with tempfile.TemporaryDirectory(prefix='lsc_protocol_')as tmp:
 p=Path(tmp);(p/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');text=execute(['vvp',p/'sim'],p,p/'sim.log');assert 'PASS' in text;print(text)
assert frozen==hashes()
(HERE/'protocol_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,configuration_errors=3,marker_errors=4,resets=4,healthy_frames=9,pending_commit_atomic=True,simulation=text.strip()),indent=2)+'\n')
