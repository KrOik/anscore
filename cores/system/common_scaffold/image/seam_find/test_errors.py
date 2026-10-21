import hashlib,json,tempfile
from pathlib import Path
import numpy as np
from test_seam import HERE,execute,costs,shortest,mask_for
a=np.array([(i*37)%256 for i in range(12)],np.uint8).reshape(3,4)
b=np.array([(250-i*19)%256 for i in range(12)],np.uint8).reshape(3,4)
cost,path=shortest(costs(a,b,7),False);mask,on=mask_for(a.shape,path,False,2)
init='\n'.join(f"p[{i}]=16'h{x:02x}{y:02x};e[{i}]=12'h{((i==11)<<11)|((i%4==3)<<10)|((i==0)<<9)|(int(z)<<8)|int(m):03x};" for i,(x,y,m,z) in enumerate(zip(a.flat,b.flat,mask.flat,on.flat)))
packed=sum(x<<(i*6) for i,x in enumerate(path))
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,cfg_valid=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[5:0]cfg_width=4,cfg_height=3,cfg_feather=2;reg cfg_horizontal=0;reg[7:0]cfg_gradient_weight=7;
 reg[7:0]s_a=0,s_b=0;
 wire cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_is_seam,done_valid,busy;
 wire[7:0]m_mask;wire[191:0]seam_coordinates;wire[5:0]seam_length;wire[31:0]total_cost;wire[3:0]error_code;
 seam_find dut(.*);
 reg[15:0]p[0:11];reg[11:0]e[0:11];integer i,phase,count=0,cycles=0,healthy_count=0;reg check_pixels=0;reg[4:0]watched;
 localparam[191:0]PATH=192'hPP;localparam[31:0]COST=CC;
 wire[11:0]token={m_last,m_eol,m_sof,m_is_seam,m_mask};
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>1000000)$fatal(1,"watchdog");
  if(rst_n&&ce&&m_valid&&m_ready&&check_pixels)begin if(count>=12||token!==e[count])$fatal(1,"healthy pixel");count=count+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;
 begin tick;rst_n=0;ce=0;cfg_valid=0;start_valid=0;abort=0;s_valid=0;m_ready=0;done_ready=0;check_pixels=0;
 tick;if(m_valid||done_valid||start_ready||s_ready||busy)$fatal(1,"CE-low reset");rst_n=1;ce=1;tick;end endtask
 task configure;
 input bad;
 begin cfg_valid=1;tick;cfg_valid=0;if(cfg_error!==bad||cfg_done===bad)$fatal(1,"config");tick;end endtask
 task start;
 begin while(!start_ready)tick;start_valid=1;tick;start_valid=0;end endtask
 task feed;
 begin for(i=0;i<12;i=i+1)begin {s_a,s_b}=p[i];s_sof=i==0;s_eol=i%4==3;s_last=i==11;s_valid=1;tick;s_valid=0;end end endtask
 task ack;
 begin done_ready=1;tick;done_ready=0;tick;end endtask
 task expect_error;
 input[3:0]code;
 begin while(!done_valid)tick;if(error_code!==code||m_valid)$fatal(1,"error result");
 abort=1;ce=0;done_ready=1;repeat(3)tick;if(!done_valid||error_code!==code)$fatal(1,"held error");
 abort=0;done_ready=0;ce=1;ack;end endtask
 task healthy;
 begin count=0;check_pixels=1;m_ready=1;start;feed;while(!done_valid)tick;
 if(error_code||count!=12||seam_coordinates!==PATH||total_cost!==COST)$fatal(1,"healthy completion");
 abort=1;repeat(3)begin tick;if(!done_valid||error_code||seam_coordinates!==PATH)$fatal(1,"late abort");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE-gated DONE");
 done_ready=0;abort=0;ce=1;ack;check_pixels=0;m_ready=0;healthy_count=healthy_count+1;end endtask
 initial begin
 INIT
 reset;cfg_width=0;configure(1);cfg_width=33;configure(1);cfg_width=4;cfg_feather=33;configure(1);cfg_feather=2;configure(0);
 cfg_height=0;configure(1);cfg_height=3;if(!start_ready||dut.height!=3)$fatal(1,"config retention");
 for(phase=0;phase<3;phase=phase+1)begin
  start;{s_a,s_b}=p[0];s_sof=phase!=0;s_eol=phase==1;s_last=phase==2;s_valid=1;tick;s_valid=0;expect_error(1);healthy;
 end
 for(phase=0;phase<4;phase=phase+1)begin
  start;if(phase!=0)feed;
  case(phase)0:watched=1;1:watched=13;2:watched=18;3:watched=26;endcase
  while(dut.state!=watched)tick;abort=1;tick;expect_error(3);healthy;
 end
 for(phase=0;phase<8;phase=phase+1)begin
  start;if(phase!=0)feed;
  case(phase)0:watched=1;1:watched=3;2:watched=10;3:watched=13;4:watched=19;5:watched=24;6:watched=26;7:watched=27;endcase
  if(phase==7)m_ready=1;
  while(dut.state!=watched)tick;reset;configure(0);healthy;
 end
 $display("ERROR PASS healthy=%d",healthy_count);$finish;end endmodule'''
for key,value in [('PP',f'{packed:x}'),('CC',cost),('INIT',init)]:tb=tb.replace(key,str(value))
sha=hashlib.sha256((HERE/'seam_find.sv').read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='seam_errors_') as td:
 td=Path(td);(td/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'seam_find.sv',td/'tb.sv'],td,td/'compile.log')
 result=execute(['vvp',td/'sim'],td,td/'run.log',timeout=300);assert 'ERROR PASS healthy=         15' in result,result
assert sha==hashlib.sha256((HERE/'seam_find.sv').read_bytes()).hexdigest()
report=dict(status='PASS',healthy_recovery_frames=15,configuration=['zero width','width33','feather33','zero height','retention'],
 marker=['missing SOF','early EOL','early LAST'],abort=['capture','DP scoring','traceback','held mask output'],
 reset_ce0=['capture','frame RAM read','gradient multiplier','DP scoring','traceback RAM read','feather divide','held mask output','held DONE'],
 held=['error completion','late abort successful DONE','CE-gated DONE acknowledgment'],rtl_sha256=sha,board=False)
(HERE/'error_evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
