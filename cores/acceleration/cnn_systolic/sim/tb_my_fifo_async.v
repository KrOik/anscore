`timescale 1ns/1ps
// Transaction-level queue scoreboard; no DUT pointer or memory inspection.
// Functional CDC exercise only: RTL simulation cannot model metastability.
module tb_my_fifo_async #(parameter DEPTH=16, WR_HALF=7, RD_HALF=11);
reg wr_clk=0,rd_clk=0,rst=1;
always #(WR_HALF) wr_clk=~wr_clk;
initial begin #2; forever #(RD_HALF) rd_clk=~rd_clk; end
reg wr_en=0,rd_en=0;
reg [15:0] din=0;
wire [15:0] dout;
wire full,empty;
my_fifo #(.DATA_WIDTH(16),.FIFO_DEPTH(DEPTH)) dut(.*);
reg [15:0] queue[0:16383];
reg [31:0] wr_rng=32'h789abcde,rd_rng=32'h12345678;
integer written=0,read_count=0,total_checked=0,phase=0,epoch;
reg [15:0] expected;
always @(negedge wr_clk) begin
 wr_rng={wr_rng[30:0],wr_rng[31]^wr_rng[21]^wr_rng[1]^wr_rng[0]};
 wr_en=!rst && ((phase==0) || (phase==2 && wr_rng[1:0]!=0));
 din=wr_rng[15:0];
end
always @(negedge rd_clk) begin
 rd_rng={rd_rng[30:0],rd_rng[31]^rd_rng[21]^rd_rng[1]^rd_rng[0]};
 rd_en=!rst && ((phase==1) || (phase==3) || (phase==2 && rd_rng[2:0]!=0));
end
always @(posedge wr_clk or posedge rst) begin
 if(rst) written=0;
 else begin
  if(full!==0 && full!==1) $fatal(1,"unknown full");
  if(wr_en && !full) begin
   if(written>=16384) $fatal(1,"scoreboard capacity");
   queue[written]=din; written=written+1;
  end
 end
end
always @(posedge rd_clk or posedge rst) begin
 if(rst) read_count=0;
 else begin
  if(empty!==0 && empty!==1) $fatal(1,"unknown empty");
  if(rd_en && !empty) begin
   if(read_count>=written) $fatal(1,"read without queued write");
   expected=queue[read_count]; read_count=read_count+1;
   #1;
   if(dout!==expected) $fatal(1,"FIFO order/data mismatch read=%0d got=%h expected=%h",read_count,dout,expected);
   total_checked=total_checked+1;
  end
 end
end
initial begin
 #53; rst=0;
 for(epoch=0;epoch<3;epoch=epoch+1) begin
  phase=0;
  wait(full); repeat(8) @(negedge wr_clk);
  if(written!=DEPTH || read_count!=0) $fatal(1,"fill capacity mismatch");
  phase=1;
  wait(empty); repeat(8) @(negedge rd_clk);
  if(read_count!=DEPTH) $fatal(1,"drain capacity mismatch");
  phase=2;
  repeat(2000) @(negedge wr_clk);
  phase=3;
  wait(empty); repeat(8) @(negedge rd_clk);
  if(read_count!=written) $fatal(1,"lost trailing data");
  // Reset with traffic in flight; queued old-epoch data is intentionally discarded.
  phase=2; repeat(37) @(negedge wr_clk);
  #2; rst=1; #47; phase=0; rst=0;
 end
 if(total_checked<500) $fatal(1,"insufficient random traffic");
 $display("PASS async FIFO DEPTH=%0d clocks=%0dns/%0dns epochs=3 checked=%0d",DEPTH,2*WR_HALF,2*RD_HALF,total_checked);
 $finish;
end
initial begin #2000000; $fatal(1,"timeout"); end
endmodule
