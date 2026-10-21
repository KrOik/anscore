"""Directed arithmetic overflow, protocol, and CE-low reset checks."""
import json,tempfile
from pathlib import Path
from test_homography_ransac import HERE,execute

tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,s_valid=0,s_first=0,s_last=0,m_ready=0;
 reg signed[15:0]s_x,s_y,s_u,s_v;
 reg[6:0]cfg_count=4;reg[15:0]cfg_iterations=1;
 wire s_ready,busy,done,m_valid,model_valid;wire[3:0]error_code;
 homography_ransac dut(.clk(clk),.rst_n(rst_n),.ce(ce),.s_x(s_x),.s_y(s_y),.s_u(s_u),.s_v(s_v),
 .s_first(s_first),.s_last(s_last),.s_valid(s_valid),.s_ready(s_ready),.cfg_count(cfg_count),
 .cfg_iterations(cfg_iterations),.cfg_seed(32'd0),.cfg_threshold(32'd131072),
 .m_ready(m_ready),.m_valid(m_valid),.model_valid(model_valid),.busy(busy),.done(done),.error_code(error_code));
 integer i,phase,cycles=0;reg[63:0]p[0:3];reg[5:0]watched;
 always @(posedge clk)begin cycles=cycles+1;if(cycles>3000000)$fatal(1,"timeout");end
 task reset;
 begin @(negedge clk);rst_n=0;ce=0;s_valid=0;@(negedge clk);
 if(m_valid||busy||model_valid||done||dut.loaded)$fatal(1,"CE-low reset");
 rst_n=1;ce=1;end endtask
 task point;
 input integer index;input first,last;
 begin @(negedge clk);{s_x,s_y,s_u,s_v}=p[index];s_first=first;s_last=last;s_valid=1;
 @(negedge clk);s_valid=0;end endtask
 task feed;
 begin for(i=0;i<4;i=i+1)point(i,i==0,i==3);end endtask
 task expect_error;
 input[3:0]code;
 begin wait(m_valid);@(negedge clk);if(error_code!=code||model_valid)$fatal(1,"protocol error");reset;end endtask
 initial begin
 p[0]=64'h000000000004fffd;p[1]=64'h00400000003efffb;
 p[2]=64'h00000040000a003a;p[3]=64'h0040004000440034;
 reset;
 // Arithmetic overflow is injected into the actual shared datapath, independently
 // of supported-coordinate fitting. No unsupported numerical claim is implied.
 @(negedge clk);dut.multiply(64'sh7fffffffffffffff,64'sh7fffffffffffffff,0);
 wait(dut.state==48);wait(dut.state==0);@(negedge clk);if(!dut.alu_bad)$fatal(1,"multiply overflow");
 @(negedge clk);dut.divide(64'sh7fffffffffffffff,64'sd1,0);
 wait(dut.state==49);wait(dut.state==0);@(negedge clk);if(!dut.alu_bad)$fatal(1,"divide overflow");
 @(negedge clk);dut.divide(64'sd1,64'sd0,0);
 wait(dut.state==49);wait(dut.state==0);@(negedge clk);if(!dut.alu_bad)$fatal(1,"divide zero");
 @(negedge clk);dut.multiply(-64'sd33554432,64'sd25165824,0);
 wait(dut.state==48);wait(dut.state==0);@(negedge clk);if(dut.alu_bad||dut.alu_result!=-64'sd50331648)$fatal(1,"signed multiply");
 @(negedge clk);dut.divide(-64'sd50331648,64'sd25165824,0);
 wait(dut.state==49);wait(dut.state==0);@(negedge clk);if(dut.alu_bad||dut.alu_result!=-64'sd33554432)$fatal(1,"signed division");
 reset;
 point(0,0,0);expect_error(2);
 point(0,1,1);expect_error(2);
 cfg_count=3;point(0,1,0);expect_error(1);cfg_count=4;
 cfg_iterations=0;point(0,1,0);expect_error(1);cfg_iterations=1;
 for(phase=0;phase<6;phase=phase+1)begin
  if(phase==0)begin point(0,1,0);reset;end
  else begin
   feed;
   case(phase)1:watched=2;2:watched=48;3:watched=49;4:watched=39;5:watched=47;endcase
   wait(dut.state==watched);reset;
  end
 end
 feed;wait(m_valid);@(negedge clk);
 if(error_code||!model_valid||dut.best_count!=4)$fatal(1,"recovery failed");
 $display("EDGE PASS");$finish;
 end
endmodule'''
with tempfile.TemporaryDirectory(prefix='homography_edges_') as td:
 td=Path(td);(td/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'homography_ransac.sv',td/'tb.sv'],td,td/'compile.log')
 assert 'EDGE PASS' in execute(['vvp',td/'sim'],td,td/'run.log',timeout=300)
result=dict(status='PASS',arithmetic=['signed multiply','signed divide','multiply overflow','divide overflow','divide zero'],
 protocol=['missing first','early last','count below4','zero budget'],
 reset_ce_low=['partial capture','matrix clear','serial multiply','serial divide','reprojection','held DONE'],board=False)
(HERE/'edge_evidence.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
