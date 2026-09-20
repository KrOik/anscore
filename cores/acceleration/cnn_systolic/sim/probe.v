module tb_probe;
reg clk=0, rst_n=0; reg [4:0] sel=0;
wire all_done, all_pass, any_fail; wire [15:0] done_mask, pass_mask; wire [31:0] dq;
cnn_selftest dut(.clk(clk),.rst_n(rst_n),.all_done(all_done),.all_pass(all_pass),
  .any_fail(any_fail),.digest_sel(sel),.digest_q(dq),.done_mask(done_mask),.pass_mask(pass_mask));
always #5 clk = ~clk;
integer i;
initial begin
  repeat(10) @(posedge clk); rst_n <= 1;
  i=0;
  while (!all_done && i<200000) begin @(posedge clk); i=i+1; end
  repeat(6) @(posedge clk);
  $display("done=%04x pass=%04x", done_mask, pass_mask);
  $display("exp0=%08x exp10=%08x d0=%08x d10=%08x",
      dut.exp_digest(4'd0), dut.exp_digest(4'd10), dut.digests[0], dut.digests[10]);
  $finish;
end
endmodule
