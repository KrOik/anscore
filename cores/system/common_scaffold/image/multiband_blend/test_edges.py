import json,tempfile
from pathlib import Path
from test_multiband import HERE,execute

tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,cfg_valid=0,start_valid=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[5:0]cfg_width=4,cfg_height=3;reg[1:0]cfg_levels=3;
 reg[7:0]s_a=21,s_b=210,s_mask=128;
 wire cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,done_valid,busy;wire[3:0]error_code;
 wire[7:0]m_data;wire m_sof,m_eol,m_last;
 multiband_blend dut(.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
 .cfg_width(cfg_width),.cfg_height(cfg_height),.cfg_levels(cfg_levels),.cfg_done(cfg_done),.cfg_error(cfg_error),
 .start_valid(start_valid),.start_ready(start_ready),.s_a(s_a),.s_b(s_b),.s_mask(s_mask),.s_valid(s_valid),
 .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_ready(s_ready),.m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),
 .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.done_valid(done_valid),.done_ready(done_ready),.busy(busy),.error_code(error_code));
 integer i,phase,cycles=0;reg[4:0]watched;reg[10:0]held;
 always @(posedge clk)begin cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout");end
 task reset;
 begin @(negedge clk);rst_n=0;ce=0;s_valid=0;start_valid=0;cfg_valid=0;m_ready=0;done_ready=0;
 @(negedge clk);if(done_valid||m_valid||busy||start_ready||s_ready)$fatal(1,"CE-low reset");
 rst_n=1;ce=1;end endtask
 task configure;
 input expected_error;
 begin @(negedge clk);cfg_valid=1;@(negedge clk);cfg_valid=0;#1;
 if(cfg_error!==expected_error||cfg_done===expected_error)$fatal(1,"config status");end endtask
 task start;
 begin @(negedge clk);if(!start_ready)$fatal(1,"start not ready");start_valid=1;@(negedge clk);start_valid=0;end endtask
 task feed;
 begin for(i=0;i<12;i=i+1)begin
 @(negedge clk);s_valid=1;s_sof=i==0;s_eol=i%4==3;s_last=i==11;@(negedge clk);s_valid=0;
 end end endtask
 task ack;
 begin @(negedge clk);done_ready=1;@(negedge clk);done_ready=0;end endtask
 initial begin
 reset;if(start_ready)$fatal(1,"unconfigured start");
 cfg_width=0;configure(1);cfg_width=33;configure(1);cfg_width=4;cfg_levels=1;configure(1);cfg_levels=3;configure(0);
 cfg_height=0;configure(1);cfg_height=3;
 if(!start_ready||dut.widths[0]!=4||dut.heights[0]!=3)$fatal(1,"bad config destroyed active");
 for(phase=0;phase<3;phase=phase+1)begin
  start;
  @(negedge clk);s_valid=1;s_sof=phase!=0;s_eol=phase==1;s_last=phase==2;
  @(negedge clk);s_valid=0;wait(done_valid);if(error_code!=1||m_valid)$fatal(1,"marker error");
  ce=0;done_ready=1;repeat(3)@(negedge clk);if(!done_valid||error_code!=1)$fatal(1,"CE gated DONE");
  done_ready=0;ce=1;ack;
 end
 for(phase=0;phase<7;phase=phase+1)begin
  start;
  if(phase==0)begin @(negedge clk);s_valid=1;s_sof=1;s_eol=0;s_last=0;@(negedge clk);s_valid=0;reset;end
  else begin
   feed;
   case(phase)1:watched=2;2:watched=23;3:watched=26;4:watched=27;5:watched=19;6:watched=20;endcase
   if(phase==6)m_ready=1;
   wait(dut.state==watched);
   if(phase==5)begin
    held={m_data,m_sof,m_eol,m_last};ce=0;m_ready=1;repeat(3)@(negedge clk);
    if(!m_valid||{m_data,m_sof,m_eol,m_last}!==held)$fatal(1,"CE gated pixel");
   end
   reset;
  end
  configure(0);
 end
 start;feed;m_ready=1;wait(done_valid);if(error_code)$fatal(1,"recovery");
 $display("EDGE PASS");$finish;end endmodule'''
with tempfile.TemporaryDirectory(prefix='multiband_edges_') as td:
 td=Path(td);(td/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'multiband_blend.sv',td/'tb.sv'],td,td/'compile.log')
 assert 'EDGE PASS' in execute(['vvp',td/'sim'],td,td/'run.log',timeout=300)
result=dict(status='PASS',configuration=['zero width','width33','invalid levels','zero height','retained prior config'],
 marker=['missing SOF','early EOL','early last'],ce_gated=['output acceptance','DONE acceptance'],
 reset_ce_low=['partial capture','pyramid build','filter RAM read','blend multiply','blend divide','held output','held DONE'],board=False)
(HERE/'edge_evidence.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
