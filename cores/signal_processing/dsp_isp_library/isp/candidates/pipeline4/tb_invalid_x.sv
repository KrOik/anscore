`timescale 1ns/1ps
module tb_invalid_x;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,valid=0,ready=0,user=0,last=0;
reg [23:0] data=24'hxxxxxx;
wire sr,mv,mu,ml,cr,ce;wire [23:0] md;
csc_stream dut(.clk(clk),.rst_n(rst_n),.s_tdata(data),.s_tvalid(valid),.s_tuser(user),.s_tlast(last),.s_tready(sr),.m_tdata(md),.m_tvalid(mv),.m_tuser(mu),.m_tlast(ml),.m_tready(ready),.cfg_valid(1'b0),.cfg_ready(cr),.cfg_mode(2'd0),.cfg_standard(1'b0),.cfg_limited(1'b0),.cfg_error(ce));
integer i;
initial begin
#1;$display("X-test time=%0t",$time);$fflush();
repeat(4) @(negedge clk);rst_n=1;user=1'bx;last=1'bx;
for(i=0;i<1000;i=i+1) begin @(negedge clk);if(mv!==0 || sr!==1) $fatal(1,"invalid X affected control");end
data=0;valid=1;user=1;last=1;@(negedge clk);valid=0;data=24'hxxxxxx;user=1'bx;last=1'bx;
wait(mv===1);
for(i=0;i<20;i=i+1) begin @(negedge clk);if(md!==24'h008080 || mu!==1 || ml!==1 || mv!==1) $fatal(1,"valid result/hold contaminated");end
ready=1;repeat(6) @(negedge clk);if(mv!==0) $fatal(1,"extra valid");
$display("PASS invalid X clock progress, recovery and held valid result time=%0t",$time);$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
