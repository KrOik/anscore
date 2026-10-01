`timescale 1ns/1ps
// Negative transport/control checks; internal watchdog forcing is test-only.
module tb_fault;

reg clk=0;always #5 clk=~clk;
reg rx=1;wire tx,dbg;
dsp_chain_harness dut(clk,rx,tx,dbg);
integer received=0,j;reg [7:0] word,bytes[0:511];
task put(input [7:0] value,input good);
integer k;begin
@(negedge clk);rx=0;repeat(234) @(negedge clk);
for(k=0;k<8;k=k+1) begin rx=value[k];repeat(234) @(negedge clk);end
rx=good;repeat(234) @(negedge clk);rx=1;repeat(234) @(negedge clk);
end endtask
task reset;
begin force dut.por=0;repeat(2) @(negedge clk);release dut.por;repeat(5000) @(negedge clk);received=0;end endtask
task header(input [7:0] count);
integer k;begin put("D",1);put("S",1);put("C",1);put("1",1);
for(k=0;k<8;k=k+1) put(0,1);put(count,1);put(0,1);end endtask
task value(input [7:0] v);begin put(v,1);put(0,1);end endtask
initial forever begin
@(negedge tx);repeat(351) @(negedge clk);
for(j=0;j<8;j=j+1) begin word[j]=tx;repeat(234) @(negedge clk);end
if(tx!==1 || dbg!==tx) $fatal(1,"bad output UART");
bytes[received]=word;received=received+1;
end
initial begin
repeat(5000) @(negedge clk);
// Truncated payload must never launch processing or emit stale RAM.
header(1);put(8'h7b,1);repeat(10000) @(negedge clk);
if(received!=0 || dut.state!=0) $fatal(1,"truncation produced output");
reset;
// Bad stop is discarded and framing status becomes visible internally.
put(8'h42,0);repeat(1000) @(negedge clk);
if(received!=0 || !dut.flags[1]) $fatal(1,"bad stop not rejected");
reset;
// Inject after flags byte was sent; must survive into next report.
header(1);value(8'h7b);wait(received>=14);put(8'h99,1);
wait(received==37);repeat(500) @(negedge clk);
if(bytes[13]!=0 || !dut.flags[2]) $fatal(1,"busy RX detection");
header(1);value(8'h7b);wait(received==74);repeat(500) @(negedge clk);
if(bytes[50]!=4 || bytes[57]!=8'h7b) $fatal(1,"late busy flag lost");
reset;
// Force watchdog boundary coincident with a captured valid result.
fork
begin header(2);value(8'h7b);value(8'h01);end
begin wait(dut.state==5 && dut.out_valid);@(negedge clk);force dut.cycles=4095;@(posedge clk);#1;release dut.cycles;end
join
wait(received==37);repeat(500) @(negedge clk);
if(bytes[12]!=1 || bytes[13]!=16 || bytes[14]<1 || bytes[15]!=1 || bytes[20]!=8'h7b) $fatal(1,"watchdog simultaneous capture count");
$display("PASS faults: truncated/badstop/late-busy/watchdog-capture");$finish;
end
initial begin #30000000;$fatal(1,"timeout");end
endmodule
