import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_invalid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[15:0]cfg_range=1;reg[3:0]cfg_max_size=2;reg signed[15:0]s_disparity=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,m_invalid,m_removed;wire[2:0]error_code;wire signed[15:0]m_disparity;
disparity_speckle #(.WIDTH(4),.HEIGHT(3),.DISP_BITS(16),.DISP_FRAC(4))dut(.*);
integer cy=0,i,n=0,k;
always @(posedge clk)begin cy=cy+1;if(cy>100000)$fatal(1,"timeout %d",dut.state);end
 task tick;begin @(negedge clk);#1;end endtask
 task launch;begin #1;if(!start_ready)$fatal(1,"start ready");start_valid=1;tick;start_valid=0;end endtask
 task ack;begin if(!done_valid)$fatal(1,"done missing");ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE ack");ce=1;tick;done_ready=0;end endtask
 task reset_core;begin rst_n=0;ce=0;tick;if(m_valid||done_valid||s_ready||start_ready)$fatal(1,"reset");rst_n=1;ce=1;tick;end endtask
 task feed;begin
 for(i=0;i<12;i=i+1)begin s_valid=1;s_disparity=i-6;s_invalid=0;s_sof=i==0;s_eol=i%4==3;s_last=i==11;tick;end s_valid=0;end endtask
 task healthy;input removeall;begin
 cfg_range=1;cfg_max_size=removeall?12:2;launch;cfg_range=0;cfg_max_size=0;feed;n=0;
 while(!done_valid)begin
 if(m_valid)begin
 if($signed(m_disparity)!=n-6||m_invalid!=removeall||m_removed!=removeall||m_sof!=(n==0)||m_eol!=(n%4==3)||m_last!=(n==11))$fatal(1,"recovery pixel%d",n);
 ce=0;m_ready=1;repeat(3)tick;if(!m_valid)$fatal(1,"CE hold");ce=1;tick;m_ready=0;n=n+1;
 end else tick;
 end
 if(done_error||error_code||n!=12)$fatal(1,"healthy completion");ack;end endtask
 initial begin repeat(2)tick;rst_n=1;tick;
 cfg_max_size=13;launch;if(!done_valid||!done_error||error_code!=1)$fatal(1,"size config");ack;cfg_max_size=2;
 for(k=0;k<3;k=k+1)begin launch;s_valid=1;s_sof=k!=0;s_eol=k==1;s_last=k==2;tick;s_valid=0;if(!done_valid||!done_error||error_code!=2)$fatal(1,"markers");ack;end
 healthy(0);healthy(1);healthy(0);
 launch;s_valid=1;s_sof=1;s_eol=0;s_last=0;tick;s_valid=0;reset_core;
 cfg_max_size=2;cfg_range=1;launch;feed;while(dut.state!=8)tick;reset_core;
 cfg_max_size=12;launch;feed;while(dut.state!=12)tick;reset_core;
 cfg_max_size=2;launch;feed;while(!m_valid)tick;reset_core;
 healthy(1);healthy(0);
 $display("PASS config_errors=1 marker_errors=3 resets=4 healthy_frames=5");$finish;end endmodule'''
frozen=hashes()
with tempfile.TemporaryDirectory(prefix='speckle_protocol_')as tmp:
 p=Path(tmp);(p/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');text=execute(['vvp',p/'sim'],p,p/'sim.log');assert 'PASS' in text;print(text)
assert frozen==hashes()
(HERE/'protocol_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,configuration_errors=1,marker_errors=3,resets=4,healthy_frames=5,simulation=text.strip()),indent=2)+'\n')
