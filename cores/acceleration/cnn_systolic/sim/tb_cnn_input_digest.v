`timescale 1ns/1ps
// For the isolated nine-cycle unit-10 digest candidate only.
module tb_cnn_input_digest;
reg clk=0,rst_n=0;
always #5 clk=~clk;
wire all_done,all_pass,any_fail;
wire [15:0] done_mask,pass_mask;
wire [31:0] digest_q;
cnn_selftest #(.UNIT_EN(16'h0400)) dut(.clk(clk),.rst_n(rst_n),
 .all_done(all_done),.all_pass(all_pass),.any_fail(any_fail),
 .digest_sel(5'd10),.digest_q(digest_q),.done_mask(done_mask),.pass_mask(pass_mask));
reg [31:0] reference_hash=32'h811c9dc5,next_hash;
reg [143:0] captured;
integer pending=0,i,checked=0,epoch;
always @(posedge clk) begin
 if(!rst_n) begin reference_hash=32'h811c9dc5;pending=0;end
 else begin
  if(dut.ce && !dut.il_done && dut.il_ov) begin
   if(pending!=0) $fatal(1,"fold overwritten by next window");
   captured=dut.il_dout;next_hash=reference_hash;
   for(i=0;i<18;i=i+1) begin
    next_hash=(next_hash ^ {24'b0,captured[7:0]})*32'h01000193;
    captured=captured>>8;
   end
   reference_hash=next_hash;pending=9;
  end else if(pending>0) begin
   pending=pending-1;
   if(pending==0) begin
    #1;
    if(dut.il_dg!==reference_hash) $fatal(1,"digest mismatch got=%h expected=%h",dut.il_dg,reference_hash);
    checked=checked+1;
   end
  end
 end
end
initial begin
 repeat(5) @(negedge clk);rst_n=1;
 for(epoch=0;epoch<2;epoch=epoch+1) begin
  wait(dut.g_u10.il_fold_busy);
  repeat(4) @(negedge clk);
  rst_n=0;repeat(5) @(negedge clk);rst_n=1;
 end
 wait(all_done);@(negedge clk);
 if(!all_pass || any_fail || dut.il_dg!==32'h41c4c21f || pending!=0 || checked<40)
  $fatal(1,"final digest/status failure checked=%0d",checked);
 $display("PASS serial input digest checked=%0d midfold_resets=2",checked);
 $finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
