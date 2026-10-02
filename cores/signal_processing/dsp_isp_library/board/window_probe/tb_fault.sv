`timescale 1ns/1ps
// Negative transport/control checks; internal watchdog forcing is test-only.
module tb_fault;
parameter WIDTH=8,HEIGHT=8,K=3,PAD_MODE=1,DATA_WIDTH=8;
localparam PIX=WIDTH*HEIGHT;
localparam REC_BYTES=(K*K*DATA_WIDTH+2+7)/8;
localparam HDR=23;
reg clk=0;always #5 clk=~clk;
reg rx=1;wire tx,dbg;
window_probe #(.DATA_WIDTH(DATA_WIDTH),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(K),.PAD_MODE(PAD_MODE)) dut(clk,rx,tx,dbg);
integer received=0,j;reg [7:0] word,bytes[0:8191];
task put(input [7:0] value,input good);
integer k;begin
@(negedge clk);rx=0;repeat(234) @(negedge clk);
for(k=0;k<8;k=k+1) begin rx=value[k];repeat(234) @(negedge clk);end
rx=good;repeat(234) @(negedge clk);rx=1;repeat(234) @(negedge clk);
end endtask
task reset;
begin force dut.por=0;repeat(2) @(negedge clk);release dut.por;repeat(5000) @(negedge clk);received=0;end endtask
task header(input [15:0] count);
integer k;begin put("W",1);put("P",1);put("R",1);put("1",1);
for(k=0;k<8;k=k+1) put(0,1);put(count[7:0],1);put(count[15:8],1);put(0,1);end endtask
task pixels(input [15:0] n);
integer k;begin for(k=0;k<n;k=k+1) put(k*8'h25+8'h11,1);end endtask
initial forever begin
@(negedge tx);repeat(351) @(negedge clk);
for(j=0;j<8;j=j+1) begin word[j]=tx;repeat(234) @(negedge clk);end
if(tx!==1 || dbg!==tx) $fatal(1,"bad output UART");
bytes[received]=word;received=received+1;
end
initial begin
repeat(5000) @(negedge clk);
// Truncated payload must never launch replay or emit stale RAM.
header(PIX);put(8'h7b,1);repeat(10000) @(negedge clk);
if(received!=0 || dut.state!=0) $fatal(1,"truncation produced output");
reset;
// Bad stop is discarded and framing status becomes visible internally.
put(8'h42,0);repeat(1000) @(negedge clk);
if(received!=0 || !dut.flags[1]) $fatal(1,"bad stop not rejected");
reset;
// Inject after flags byte was sent; must survive into next report.
header(PIX);pixels(PIX);wait(received>=14);put(8'h99,1);
wait(received==HDR+PIX*REC_BYTES);repeat(500) @(negedge clk);
if(bytes[14]!=0 || !dut.flags[2]) $fatal(1,"busy RX detection");
header(PIX);pixels(PIX);wait(received==2*(HDR+PIX*REC_BYTES));repeat(500) @(negedge clk);
if(bytes[HDR+PIX*REC_BYTES+14]!=4) $fatal(1,"late busy flag lost");
reset;
// Force watchdog boundary coincident with a captured valid window.
fork
begin header(PIX);pixels(PIX);end
begin wait(dut.state==5 && dut.win_valid);@(negedge clk);force dut.cycles=dut.WATCHDOG-1;@(posedge clk);#1;release dut.cycles;end
join
wait(received>=HDR);repeat(500) @(negedge clk);
if({bytes[13],bytes[12]}==PIX || bytes[14]!=16 || {bytes[18],bytes[17]}!={bytes[13],bytes[12]})
  $fatal(1,"watchdog partial capture count");
$display("PASS faults: truncated/badstop/late-busy/watchdog-capture");$finish;
end
initial begin #3000000000;$fatal(1,"timeout");end
endmodule
