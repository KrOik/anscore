import hashlib,json,tempfile
from pathlib import Path
import numpy as np
from test_pipeline import HERE,PACKAGE,SOURCES,execute,golden
a=np.array([(i*37)%256 for i in range(12)],np.uint8).reshape(3,4)
b=np.array([(250-i*19)%256 for i in range(12)],np.uint8).reshape(3,4)
out,mask,cost,path=golden(a,b,False,7,2,3)
init='\n'.join(f"p[{i}]=16'h{x:02x}{y:02x};e[{i}]=11'h{((i==11)<<10)|((i%4==3)<<9)|((i==0)<<8)|int(z):03x};" for i,(x,y,z) in enumerate(zip(a.flat,b.flat,out.flat)))
packed=sum(x<<(i*6) for i,x in enumerate(path))
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,cfg_valid=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[5:0]cfg_width=4,cfg_height=3,cfg_feather=2;reg cfg_horizontal=0;reg[7:0]cfg_gradient_weight=7;reg[1:0]cfg_levels=3;
 reg[7:0]s_a=0,s_b=0;
 wire cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;
 wire[7:0]m_data,error_code;wire[191:0]seam_coordinates;wire[5:0]seam_length;wire[31:0]total_cost;
 seam_multiband_blend dut(.*);
 reg[15:0]p[0:11];reg[10:0]e[0:11];integer i,phase,count=0,cycles=0,healthy_count=0;reg check_pixels=0;
 localparam[191:0]PATH=192'hPP;localparam[31:0]COST=CC;
 wire[10:0]token={m_last,m_eol,m_sof,m_data};
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>3000000)$fatal(1,"watchdog top=%d s=%d b=%d phase=%d healthy=%d",dut.state,dut.seam.state,dut.blend.state,phase,healthy_count);
  if(rst_n&&ce&&m_valid&&m_ready&&check_pixels)begin if(count>=12||token!==e[count])$fatal(1,"healthy pixel %d",count);count=count+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;
 begin tick;rst_n=0;ce=0;cfg_valid=0;start_valid=0;abort=0;s_valid=0;m_ready=0;done_ready=0;check_pixels=0;
 tick;if(m_valid||done_valid||start_ready||s_ready||busy)$fatal(1,"CE-low reset");rst_n=1;ce=1;tick;end endtask
 task configure;
 input bad;
 begin while(!cfg_ready)tick;cfg_valid=1;tick;cfg_valid=0;
 while(!cfg_done&&!cfg_error)tick;if(cfg_error!==bad||cfg_done===bad)$fatal(1,"configuration");tick;end endtask
 task start;
 begin while(!start_ready)tick;start_valid=1;tick;start_valid=0;end endtask
 task feed;
 begin for(i=0;i<12;i=i+1)begin {s_a,s_b}=p[i];s_sof=i==0;s_eol=i%4==3;s_last=i==11;while(!s_ready)tick;s_valid=1;tick;s_valid=0;end end endtask
 task ack;
 begin done_ready=1;tick;done_ready=0;tick;end endtask
 task expect_error;
 input[7:0]code;
 begin while(!done_valid)tick;if(error_code!==code||!done_error||m_valid)$fatal(1,"error result got=%h expected=%h",error_code,code);
 abort=1;repeat(3)begin tick;if(!done_valid||error_code!==code||!done_error||m_valid)$fatal(1,"held error");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid||error_code!==code)$fatal(1,"CE-gated error ACK");
 abort=0;done_ready=0;ce=1;ack;
 while(!start_ready)tick;
 if(dut.seam.width!=4||dut.seam.height!=3||dut.blend.widths[0]!=4||dut.blend.heights[0]!=3||dut.blend.levels!=3)$fatal(1,"automatic child configuration restore");
 end endtask
 task healthy;
 begin count=0;check_pixels=1;m_ready=1;start;feed;while(!done_valid)tick;
 if(done_error||error_code||count!=12||seam_coordinates!==PATH||total_cost!==COST)$fatal(1,"healthy completion");
 abort=1;repeat(3)begin tick;if(!done_valid||done_error||error_code||seam_coordinates!==PATH)$fatal(1,"late abort");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE-gated successful ACK");
 done_ready=0;abort=0;ce=1;ack;check_pixels=0;m_ready=0;healthy_count=healthy_count+1;end endtask
 initial begin
 INIT
 reset;cfg_width=0;configure(1);cfg_width=33;configure(1);cfg_width=4;configure(0);
 // Each invalid configuration would be accepted by one child if prevalidation
 // were absent. Neither child may receive the half-valid transaction.
 cfg_width=2;cfg_height=2;cfg_levels=1;cfg_horizontal=1;configure(1);
 if(dut.seam.width!=4||dut.blend.widths[0]!=4)$fatal(1,"half committed invalid levels");
 cfg_levels=3;cfg_feather=33;configure(1);
 if(dut.seam.width!=4||dut.blend.widths[0]!=4)$fatal(1,"half committed invalid feather");
 cfg_width=4;cfg_height=3;cfg_feather=2;cfg_horizontal=0;healthy;
 for(phase=0;phase<3;phase=phase+1)begin
  start;{s_a,s_b}=p[0];s_sof=phase!=0;s_eol=phase==1;s_last=phase==2;s_valid=1;tick;s_valid=0;expect_error(8'h11);healthy;
 end
 for(phase=0;phase<5;phase=phase+1)begin
  start;if(phase!=0)feed;
  case(phase)
   0:while(dut.state!=2)tick;
   1:while(dut.seam.state!=13)tick;
   2:while(!(dut.replay_state==1&&dut.replay_index>0&&dut.replay_index<12))tick;
   3:while(dut.blend.state!=24)tick;
   4:while(!m_valid)tick;
  endcase
  abort=1;
  if(phase==4)begin
   m_ready=1;#1;
   if(!dut.bm_valid||m_valid||dut.blend.m_ready)$fatal(1,"abort output handshake mismatch");
   @(posedge clk);if(m_valid&&m_ready)$fatal(1,"abort leaked external transfer");
   tick;m_ready=0;
  end else tick;
  expect_error(8'h93);healthy;
 end
 // Directed injected child terminal error at a valid and ready output boundary.
 start;feed;while(!m_valid)tick;
 force dut.b_done=1'b1;force dut.b_error=4'h1;m_ready=1;#1;
 if(!dut.bm_valid||m_valid||dut.blend.m_ready)$fatal(1,"child error output handshake mismatch");
 @(posedge clk);if(m_valid&&m_ready)$fatal(1,"child error leaked external transfer");
 tick;release dut.b_done;release dut.b_error;m_ready=0;expect_error(8'h21);healthy;
 for(phase=0;phase<8;phase=phase+1)begin
  start;if(phase!=0)feed;
  case(phase)
   0:while(dut.state!=2)tick;
   1:while(dut.seam.state!=3)tick;
   2:while(dut.seam.state!=13)tick;
   3:while(dut.seam.state!=19)tick;
   4:while(!(dut.replay_state==1&&dut.replay_index>0&&dut.replay_index<12))tick;
   5:while(dut.blend.state!=27)tick;
   6:while(!m_valid)tick;
   7:begin m_ready=1;while(!done_valid)tick;end
  endcase
  reset;configure(0);healthy;
 end
 // Reset while a two-child configuration is awaiting completion.
 while(!cfg_ready)tick;cfg_valid=1;tick;cfg_valid=0;reset;configure(0);healthy;
 $display("ERROR PASS healthy=%d",healthy_count);$finish;end endmodule'''
for k,v in [('PP',f'{packed:x}'),('CC',cost),('INIT',init)]:tb=tb.replace(k,str(v))
hashes={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
with tempfile.TemporaryDirectory(prefix='seam_multiband_errors_') as td:
 td=Path(td);(td/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
 result=execute(['vvp',td/'sim'],td,td/'run.log',timeout=300);assert 'ERROR PASS healthy=         19' in result,result
assert hashes=={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
report=dict(status='PASS',healthy_recovery_frames=19,handshake_blocking=['abort at valid and ready output edge','injected child error at valid and ready output edge'],configuration=['zero width','width33','invalid levels no half commit','invalid feather no half commit','retention'],
 marker=['missing SOF','early EOL','early LAST'],abort=['capture','seam DP','synchronous replay','multiband filtering','held output'],
 reset_ce0=['capture','seam frame read','seam DP','seam traceback','synchronous replay','multiband divider','held output','held DONE','child config handshake'],
 held=['error completion','late abort successful DONE','CE-gated DONE acknowledgment'],
 recovery='After every error ACK, both reset children automatically reconfigured before START; every healthy frame checked for exact output/markers/path/cost',sources=hashes,board=False)
(HERE/'error_evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
