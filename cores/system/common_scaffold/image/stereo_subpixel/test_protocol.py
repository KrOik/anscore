"""Multi-pixel packet order, CE, completion, configuration atomicity and abort/reset recovery."""
from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,abort=0,cfg_valid=0,s_valid=0,s_cost_invalid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[15:0]cfg_min_gap=2,s_cost,s_disp;wire cfg_ready,s_ready,m_invalid,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[3:0]error_code;wire signed[31:0]m_disparity_q;wire[15:0]m_integer,m_confidence;wire signed[4:0]m_offset;wire[7:0]m_status;
stereo_subpixel #(.WIDTH(2),.HEIGHT(2))dut(.*);
integer p,d,rep,test,cycles=0;reg[90:0]held;
always @(posedge clk)begin cycles=cycles+1;if(cycles>200000)$fatal(1,"timeout state=%d",dut.state);end
 task tick;begin @(negedge clk);#1;end endtask
 task cfg;begin cfg_valid=1;cfg_min_gap=2;tick;cfg_valid=0;#1;end endtask
 task ack;begin if(!done_valid)$fatal(1,"missing done");ce=0;done_ready=1;repeat(2)tick;if(!done_valid)$fatal(1,"done pause");ce=1;tick;done_ready=0;end endtask
 task cost;input integer pp,dd;begin
 s_disp=dd;s_cost=100+4*(dd-(pp+2))*(dd-(pp+2))+2*(dd-(pp+2));s_cost_invalid=0;s_sof=pp==0;s_eol=pp%2==1;s_last=pp==3;s_valid=1;tick;s_valid=0;end endtask
 task frame;begin
 for(p=0;p<4;p=p+1)begin
 for(d=0;d<16;d=d+1)begin if(!s_ready)$fatal(1,"axis ready");cost(p,d);if(p==0&&d==0)begin cfg_valid=1;cfg_min_gap=65535;end end
 while(!m_valid)tick;
 if(m_disparity_q!=(p+2)*16-4||m_integer!=p+2||m_offset!=-4||m_confidence!=2||m_invalid||m_status!=1||m_sof!=(p==0)||m_eol!=(p%2==1)||m_last!=(p==3))$fatal(1,"pixel %d q=%d inv=%d status=%d",p,m_disparity_q,m_invalid,m_status);
 if(cfg_ready)$fatal(1,"busy config");held={m_disparity_q,m_integer,m_offset,m_confidence,m_invalid,m_status,m_sof,m_eol,m_last};
 ce=0;m_ready=1;repeat(3)tick;if(!m_valid||{m_disparity_q,m_integer,m_offset,m_confidence,m_invalid,m_status,m_sof,m_eol,m_last}!==held)$fatal(1,"output pause");ce=1;tick;m_ready=0;
 end cfg_valid=0;if(!done_valid||frame_error||error_code)$fatal(1,"healthy done");ack;end endtask
 task reset_core;begin ce=0;rst_n=0;tick;if(m_valid||done_valid||s_ready||cfg_ready)$fatal(1,"reset CE");rst_n=1;ce=1;cfg;end endtask
 initial begin repeat(3)tick;rst_n=1;cfg;frame;frame;
 // Every marker and axis-index fault must terminate and allow a full frame restart.
 for(test=0;test<4;test=test+1)begin
 s_disp=test==0?1:0;s_sof=test!=1;s_eol=test==2;s_last=test==3;s_cost=1;s_valid=1;tick;s_valid=0;
 if(!done_valid||!frame_error||error_code!=1||m_valid)$fatal(1,"packet error %d",test);ack;frame;end
 // Changing markers inside an otherwise legal disparity axis is not accepted.
 cost(0,0);s_disp=1;s_sof=0;s_eol=0;s_last=0;s_cost=1;s_valid=1;tick;s_valid=0;
 if(!done_valid||error_code!=1)$fatal(1,"mid-axis marker");ack;frame;
 // Abort partial input, division and a pending output, held through a CE pause.
 for(test=0;test<3;test=test+1)begin
 if(test==0)cost(0,0);
 else begin for(d=0;d<16;d=d+1)cost(0,d);if(test==1)begin while(dut.state!=2)tick;end else while(!m_valid)tick;end
 ce=0;abort=1;repeat(3)tick;if(m_valid||s_ready)$fatal(1,"abort suppress");ce=1;tick;abort=0;
 if(!done_valid||!frame_error||error_code!=3)$fatal(1,"abort done");ack;frame;end
 // Synchronous reset overrides CE and clears partial cost, division and pending output.
 for(test=0;test<3;test=test+1)begin
 if(test==0)cost(0,0);
 else begin for(d=0;d<16;d=d+1)cost(0,d);if(test==1)begin while(dut.state!=2)tick;end else while(!m_valid)tick;end
 reset_core;frame;end
 $display("PASS stereo_subpixel protocol:13 healthy 2x2 frames,5 packet errors,3 abort phases,3 CE-disabled reset phases,config atomicity");$finish;end endmodule'''
with tempfile.TemporaryDirectory(prefix='subpixel_protocol_') as td:
 p=Path(td);(p/'tb.sv').write_text(TB)
 execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'stereo_subpixel.sv',p/'tb.sv'],ROOT,H/'protocol_compile.log')
 result=execute(['vvp',p/'sim'],p,H/'protocol_simulation.log');assert 'PASS stereo_subpixel protocol' in result;print(result.strip())
(H/'protocol_evidence.json').write_text(json.dumps({'result':'PASS','healthy_frames':13,'pixels':52,'packet_errors':5,'abort_phases':3,'reset_ce_disabled_phases':3,'configuration_atomicity':True,'rtl_sha256':hashlib.sha256((H/'stereo_subpixel.sv').read_bytes()).hexdigest()},indent=2)+'\n')

