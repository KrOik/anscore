"""True concurrent inactive-table loading, atomic publication and stream fault recovery."""
from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,cfg_begin_valid=0,cfg_valid=0,cfg_commit_valid=0,cfg_abort=0,cfg_done_ready=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[2:0]cfg_index;reg[7:0]cfg_value,s_pixel;wire cfg_begin_ready,cfg_ready,cfg_commit_ready,cfg_done_valid,cfg_error,table_active_valid,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[3:0]cfg_error_code,error_code;wire[7:0]m_pixel;
raw_gamma #(.WIDTH(16),.HEIGHT(2),.BITS(8),.OUT_BITS(8),.INDEX_BITS(2))dut(.*);
integer cycles=0,got=0,want=17,frames=0,i,j,test;reg monitor=0,stalled=0;reg[10:0]held;
wire[10:0]token={m_pixel,m_sof,m_eol,m_last};
always @(posedge clk)begin cycles=cycles+1;if(cycles>100000)$fatal(1,"timeout state%d cfg%d",dut.state,dut.cstate);
 if(rst_n&&monitor&&!abort)begin
 if(stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=m_valid&&(!ce||!m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin if(m_pixel!=want||m_sof!=(got%32==0)||m_eol!=(got%16==15)||m_last!=(got%32==31))$fatal(1,"atomic pixel got%d want%d idx%d",m_pixel,want,got);got=got+1;end
 end else stalled=0;end
 task tick;begin @(negedge clk);#1;end endtask
 task beginlut;begin cfg_begin_valid=1;tick;cfg_begin_valid=0;#1;end endtask
 task nodes;input integer count,value,duplicate;integer k;begin for(k=0;k<count;k=k+1)begin cfg_valid=1;cfg_index=duplicate?0:k;cfg_value=value;tick;end cfg_valid=0;#1;end endtask
 task commit;begin cfg_commit_valid=1;tick;cfg_commit_valid=0;#1;end endtask
 task ackcfg;input integer error,code;begin if(!cfg_done_valid||cfg_error!=error||(error&&cfg_error_code!=code))$fatal(1,"cfg result %d %d",cfg_error,cfg_error_code);cfg_done_ready=1;tick;cfg_done_ready=0;#1;end endtask
 task load;input integer value;begin beginlut;nodes(5,value,0);commit;ackcfg(0,0);end endtask
 task launch;begin start_valid=1;tick;start_valid=0;#1;end endtask
 task ackframe;input integer error,code;begin if(!done_valid||frame_error!=error||(error&&error_code!=code))$fatal(1,"frame result %d %d",frame_error,error_code);ce=0;done_ready=1;repeat(2)tick;if(!done_valid)$fatal(1,"done pause");ce=1;tick;done_ready=0;#1;end endtask
 task beat;input integer p;begin s_pixel=p*7;s_valid=1;s_sof=p==0;s_eol=p%16==15;s_last=p==31;begin:waitbeat reg take;take=0;while(!take)begin @(posedge clk);take=ce&&s_ready;@(negedge clk);#1;end end s_valid=0;#1;end endtask
 task send;integer k;begin for(k=0;k<32;k=k+1)beat(k);end endtask
 task finish;begin while(!done_valid)tick;if(got!=(frames+1)*32)$fatal(1,"count");frames=frames+1;ackframe(0,0);end endtask
 task healthy;input integer value;begin want=value;monitor=1;launch;m_ready=1;send;finish;monitor=0;end endtask
 task reset;begin ce=0;rst_n=0;tick;if(table_active_valid||cfg_done_valid||m_valid||done_valid||s_ready)$fatal(1,"reset");rst_n=1;ce=1;tick;end endtask
 initial begin repeat(3)tick;rst_n=1;launch;ackframe(1,2);load(17);
 // Load a new table concurrently with a backpressured frame. Its pending commit must wait.
 want=17;monitor=1;launch;m_ready=0;
 fork
 begin send;end
 begin beginlut;nodes(5,201,0);cfg_commit_valid=1;repeat(8)begin tick;if(cfg_commit_ready)$fatal(1,"busy commit");end m_ready=1;end
 join
 while(!done_valid)begin if(cfg_commit_ready)$fatal(1,"busy publish");tick;end
 if(cfg_commit_ready)$fatal(1,"done publish");finish;monitor=0;
 while(!cfg_done_valid)tick;cfg_commit_valid=0;ackcfg(0,0);healthy(201);
 // Incomplete, duplicate, bad-index and aborted configurations preserve active table.
 beginlut;nodes(4,7,0);commit;ackcfg(1,1);healthy(201);
 beginlut;nodes(5,7,1);commit;ackcfg(1,1);healthy(201);
 beginlut;cfg_valid=1;cfg_index=7;cfg_value=9;tick;cfg_valid=0;ackcfg(1,2);healthy(201);
 beginlut;nodes(2,7,0);ce=0;cfg_abort=1;repeat(2)tick;ce=1;tick;cfg_abort=0;ackcfg(1,3);healthy(201);
 // Every source marker is checked independently, followed by a complete healthy frame.
 for(test=0;test<3;test=test+1)begin launch;s_valid=1;s_sof=test!=0;s_eol=test==1;s_last=test==2;s_pixel=0;tick;s_valid=0;ackframe(1,1);healthy(201);end
 // Abort each elastic stage with output backpressure and a CE pause.
 for(test=1;test<=3;test=test+1)begin launch;m_ready=0;for(j=0;j<test;j=j+1)beat(j);ce=0;abort=1;repeat(2)tick;if(s_ready||m_valid)$fatal(1,"abort suppress");ce=1;tick;abort=0;ackframe(1,3);healthy(201);end
 // Reset every pipeline stage while CE=0; active LUT validity must be lost.
 for(test=1;test<=3;test=test+1)begin launch;m_ready=0;for(j=0;j<test;j=j+1)beat(j);reset;launch;ackframe(1,2);load(17);healthy(17);end
 $display("PASS raw_gamma protocol:15 healthy frames480pixels;inactive load/pending atomic commit;4 bad LUTs;3 markers;3 abort/reset stages");$finish;end endmodule'''
with tempfile.TemporaryDirectory(prefix='raw_gamma_protocol_') as td:
 p=Path(td);(p/'tb.sv').write_text(TB)
 execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'raw_gamma.sv',p/'tb.sv'],ROOT,H/'protocol_compile.log')
 text=execute(['vvp',p/'sim'],p,H/'protocol_simulation.log');assert 'PASS raw_gamma protocol' in text;print(text.strip())
(H/'protocol_evidence.json').write_text(json.dumps({'result':'PASS','healthy_frames':15,'pixels':480,'bad_tables':4,'source_marker_faults':3,'abort_pipeline_stages':3,'reset_ce_disabled_pipeline_stages':3,'concurrent_inactive_load_pending_atomic_commit':True,'rtl_sha256':hashlib.sha256((H/'raw_gamma.sv').read_bytes()).hexdigest()},indent=2)+'\n')
