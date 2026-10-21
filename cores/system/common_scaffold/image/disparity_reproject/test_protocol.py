import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cfg_valid=0,cfg_commit_valid=0,start_valid=0,s_valid=0,s_invalid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[3:0]cfg_index;reg signed[7:0]cfg_value,s_disparity=2;
wire cfg_ready,cfg_commit_ready,cfg_error,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,m_invalid,m_wzero,m_wnegative;wire[2:0]error_code,m_saturated;wire signed[15:0]m_x,m_y,m_z;
disparity_reproject #(.WIDTH(2),.HEIGHT(2),.DISP_BITS(8),.DISP_FRAC(0),.Q_BITS(8),.Q_FRAC(0),.OUT_BITS(16),.OUT_FRAC(2))dut(.*);
integer cy=0,i,n=0;
always @(posedge clk)begin cy=cy+1;if(cy>100000)$fatal(1,"timeout %d",dut.state);end
 task tick;begin @(negedge clk);#1;end endtask
 task configq;begin
 for(i=0;i<16;i=i+1)begin cfg_index=i;cfg_value=i%5==0?1:0;cfg_valid=1;tick;end
 cfg_valid=0;cfg_commit_valid=1;tick;cfg_commit_valid=0;#1;if(cfg_error||!start_ready)$fatal(1,"config");end endtask
 task launch;begin #1;if(!start_ready)$fatal(1,"no start ready");start_valid=1;tick;start_valid=0;end endtask
 task ack;begin if(!done_valid)$fatal(1,"no done");ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE ack");ce=1;tick;done_ready=0;end endtask
 task reset_core;begin ce=0;rst_n=0;tick;if(done_valid||m_valid||s_ready||cfg_ready||start_ready)$fatal(1,"reset");rst_n=1;ce=1;tick;if(start_ready)$fatal(1,"stale config");configq;end endtask
 task firstpixel;begin launch;s_valid=1;s_invalid=0;s_sof=1;s_eol=0;s_last=0;tick;s_valid=0;end endtask
 task frame;begin
 launch;n=0;
 for(i=0;i<4;i=i+1)begin
 s_valid=1;s_disparity=2;s_invalid=0;s_sof=i==0;s_eol=i%2==1;s_last=i==3;
 while(!s_ready)tick;tick;s_valid=0;
 while(!m_valid)tick;
 if($signed(m_x)!=(i%2)*4||$signed(m_y)!=(i/2)*4||$signed(m_z)!=8||m_invalid||m_saturated||m_wnegative||m_wzero)$fatal(1,"atomic config/recovery %d xyz%d %d %d",i,m_x,m_y,m_z);
 ce=0;m_ready=1;repeat(2)tick;if(!m_valid)$fatal(1,"CE output");ce=1;tick;m_ready=0;n=n+1;
 end
 if(!done_valid||done_error||n!=4)$fatal(1,"good done");ack;end endtask
 initial begin repeat(2)tick;rst_n=1;tick;
 if(start_ready)$fatal(1,"unconfigured");cfg_commit_valid=1;tick;cfg_commit_valid=0;if(!cfg_error||start_ready)$fatal(1,"incomplete first commit");
 configq;frame;
 // Partial shadow config must not change committed active matrix, even after a rejected commit.
 cfg_valid=1;cfg_index=0;cfg_value=7;tick;cfg_valid=0;cfg_commit_valid=1;tick;cfg_commit_valid=0;#1;if(!cfg_error||!start_ready)$fatal(1,"atomic partial commit");frame;
 // Duplicate index writes must not count as sixteen distinct values.
 reset_core;cfg_valid=1;cfg_index=0;repeat(16)tick;cfg_valid=0;cfg_commit_valid=1;tick;cfg_commit_valid=0;if(!cfg_error)$fatal(1,"duplicate mask");
 // SOF/EOL/LAST errors terminate promptly and allow another full frame.
 for(n=0;n<3;n=n+1)begin launch;s_valid=1;s_sof=n!=0;s_eol=n==1;s_last=n==2;tick;s_valid=0;if(!done_valid||!done_error||error_code!=1)$fatal(1,"markers");ack;end
 frame;
 firstpixel;repeat(10)tick;reset_core; // reset mid multiplication
 firstpixel;while(dut.state!=7)tick;repeat(10)tick;reset_core; // reset mid division
 firstpixel;while(!m_valid)tick;reset_core; // reset stalled output
 launch;reset_core; // reset awaiting input
 frame;
 $display("PASS commits=3 marker_errors=3 resets=5 recovery_frames=4");$finish;end endmodule'''
frozen=hashes()
with tempfile.TemporaryDirectory(prefix='reproject_protocol_')as tmp:
 p=Path(tmp);(p/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');text=execute(['vvp',p/'sim'],p,p/'sim.log');assert 'PASS' in text;print(text)
assert frozen==hashes()
(HERE/'protocol_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,configuration_rejections=3,marker_errors=3,resets=5,recovery_frames=4,simulation=text.strip()),indent=2)+'\n')
