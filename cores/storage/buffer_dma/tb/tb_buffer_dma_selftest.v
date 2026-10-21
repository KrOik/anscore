`timescale 1ns/1ps
module tb_buffer_dma_selftest;
 reg clk=0,rst=0,start=0,stalls=0;reg [31:0] seed=0;
 always #5 clk=~clk;
 wire ready,done,error;wire [31:0] words,errors,cycles;wire [7:0] probe;
 buffer_dma_selftest #(.SLOT_WORDS(16)) dut(
 .clk(clk),.rst_n(rst),.start(start),.seed(seed),.stalls_enable(stalls),
 .start_ready(ready),.done(done),.error(error),.checked_words(words),.check_errors(errors),.run_cycles(cycles),.probe(probe),
 .csr_valid(1'b0),.csr_write(1'b0),.csr_addr(8'd0),.csr_data(32'd0),.csr_strobe(4'hf),.csr_resp_ready(1'b1));
 integer run_id=0;
 always @(posedge clk)if(rst&&dut.phase==2)for(integer c=0;c<2;c=c+1)
  if(dut.mv[c]&&dut.mr[c])$display("SELF_READ run=%0d sink=%0d source=%0d frame=%0d offset=%0d data=%08h",
   run_id,c,dut.descriptors[c*66+49],dut.descriptors[c*66+50+:16],dut.offsets[c],dut.md[c*32+:32]);
 task launch(input integer id,input [31:0] value,input bit stall_mode);
 begin
  @(negedge clk);if(!ready)$fatal(1,"not restartable");run_id=id;seed=value;stalls=stall_mode;start=1;
  @(negedge clk);start=0;
 end endtask
 task finish(input bit expected_error);
 begin
  wait(done);@(negedge clk);
  if(error!==expected_error||words!=544||(expected_error?errors==0:errors!=0))$fatal(1,"selftest completion error");
  repeat(5)begin @(negedge clk);if(!done||!ready)$fatal(1,"completion not sticky");end
  $display("RUN_PASS run=%0d seed=%08h stalls=%0d error=%0d words=%0d cycles=%0d",run_id,seed,stalls,error,words,cycles);
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  launch(1,32'h512a309b,1);finish(0);
  launch(2,32'h00000001,0);finish(0);
  launch(3,32'hdeadcafe,1);
  wait(dut.mv[0]);@(negedge clk);force dut.md[31:0]=0;
  do @(posedge clk);while(!dut.mr[0]);
  @(negedge clk);release dut.md[31:0];finish(1);
  launch(4,32'h512a309b,1);finish(0);
  $display("PASS synthesizable selftest 4 runs, repeatability, restart and corruption detection");$finish;
 end
 initial begin #5000000;$fatal(1,"timeout");end
endmodule

module tb_buffer_dma_timeout;
 reg clk=0,rst=0,start=0;always #5 clk=~clk;
 wire ready,done,error;wire [31:0] words,errors,cycles;
 buffer_dma_selftest #(.SLOT_WORDS(16),.TIMEOUT(64)) dut(
 .clk(clk),.rst_n(rst),.start(start),.seed(32'd0),.stalls_enable(1'b0),
 .start_ready(ready),.done(done),.error(error),.checked_words(words),.check_errors(errors),.run_cycles(cycles),
 .csr_valid(1'b0),.csr_write(1'b0),.csr_addr(8'd0),.csr_data(32'd0),.csr_strobe(4'hf),.csr_resp_ready(1'b1));
 initial begin
  force dut.mr=0;
  repeat(4)@(negedge clk);rst=1;start=1;
  @(negedge clk);start=0;
  wait(done);@(negedge clk);
  if(!error||cycles!=64||words!=0||!ready)$fatal(1,"watchdog contract");
  $display("PASS selftest watchdog stops at 64 cycles with stalled consumers");$finish;
 end
 initial begin #10000;$fatal(1,"timeout harness");end
endmodule
