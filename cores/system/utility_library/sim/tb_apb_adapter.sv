`timescale 1ns/1ps
module tb_apb_adapter;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,psel=0,penable=0,pwrite=0;
reg [7:0] paddr=0;
reg [31:0] pwdata=0;
wire [31:0] prdata,a,b,c;
wire pready,pslverr,in_valid,out_ready,irq;
reg in_ready=0,out_valid=0,fault=0;
reg [31:0] result=0,aux=0;
prod_apb3_adapter dut(.*);
task access;
input wr; input [7:0] address; input [31:0] data; input expect_error;
begin
    @(negedge clk); psel=1; penable=0; pwrite=wr; paddr=address; pwdata=data;
    @(negedge clk); penable=1; #1;
    if(pslverr!==expect_error || pready!==1) $fatal(1,"APB response failed addr=%h",address);
    @(posedge clk); @(negedge clk); psel=0; penable=0;
end
endtask
task read_equals;
input [7:0] address; input [31:0] expected;
begin
    @(negedge clk); psel=1; penable=0; pwrite=0; paddr=address;
    @(negedge clk); penable=1; #1;
    if(prdata!==expected || pslverr!==0) $fatal(1,"APB read failed addr=%h got=%h expected=%h",address,prdata,expected);
    @(posedge clk); @(negedge clk); psel=0; penable=0;
end
endtask
initial begin
    repeat(3) @(negedge clk); rst_n=1;
    read_equals(8'h20,32'h50323501);
    access(1,4,32'h12345678,0); access(1,8,32'h9abcdef0,0); access(1,12,32'h2500,0);
    access(1,0,1,0);
    repeat(5) @(posedge clk);
    if(in_valid!==1 || {a,b,c}!==96'h123456789abcdef000002500) $fatal(1,"request changed under stall");
    access(1,4,0,1); access(1,0,1,1);
    @(negedge clk); in_ready=1;
    @(posedge clk); @(negedge clk); in_ready=0;
    read_equals(8'h18,1);
    @(negedge clk); out_valid=1; result=32'hcafebabe; aux=5; fault=1;
    @(posedge clk); @(negedge clk); out_valid=0;
    read_equals(0,6); read_equals(8'h10,32'hcafebabe); read_equals(8'h14,5); read_equals(8'h1c,1);
    if(irq!==1) $fatal(1,"completion IRQ missing");
    access(1,0,2,0); read_equals(0,0);
    access(0,8'h03,0,1); access(0,8'h24,0,1); access(1,8'h10,0,1); access(1,0,4,1);
    access(1,0,1,0); // reset while request is waiting
    @(negedge clk); rst_n=0; #1;
    if(in_valid!==0 || irq!==0) $fatal(1,"APB reset failed");
    $display("PASS APB adapter: stalls, results, IRQ, invalid accesses, reset"); $finish;
end
initial begin #100000; $fatal(1,"APB timeout"); end
endmodule
