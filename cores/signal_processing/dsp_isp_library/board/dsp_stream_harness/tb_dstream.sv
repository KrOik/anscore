`timescale 1ns/1ps
module tb_dstream;
parameter CORE=0;
reg clk=0;always #5 clk=~clk;
reg rx=1;wire tx,dbg;
dsp_stream_harness #(.CORE(CORE)) dut(clk,rx,tx,dbg);
integer f,g,n,b,i,j,len,received=0,target=0,packet=0;reg [7:0] data,word;
reg [1023:0] stim,trace;
task put(input [7:0] value);
integer k;begin
@(negedge clk);rx=0;repeat(234) @(negedge clk);
for(k=0;k<8;k=k+1) begin rx=value[k];repeat(234) @(negedge clk);end
rx=1;repeat(234) @(negedge clk);repeat(234) @(negedge clk);
end endtask
initial begin
if(!$value$plusargs("stim=%s",stim)) $fatal;
if(!$value$plusargs("trace=%s",trace)) $fatal;
f=$fopen(stim,"r");g=$fopen(trace,"w");repeat(5000) @(negedge clk);
while(!$feof(f)) begin
n=$fscanf(f,"%d %d\n",len,target);
if(n==2) begin
received=0;
for(i=0;i<len;i=i+1) begin n=$fscanf(f,"%h\n",data);put(data);end
$display("packet sent=%0d time=%0t received=%0d target=%0d state=%0d",packet,$time,received,target,dut.state);$fflush();
wait(received==target);repeat(500) @(negedge clk);packet=packet+1;
$display("packet complete=%0d time=%0t received=%0d",packet,$time,received);$fflush(g);$fflush();
end
end
$display("PASS UART block packets=%0d",packet);$fclose(g);$finish;
end
initial forever begin
@(negedge tx);repeat(351) @(negedge clk);
for(j=0;j<8;j=j+1) begin word[j]=tx;repeat(234) @(negedge clk);end
if(tx!==1 || dbg!==tx) $fatal(1,"UART framing/mirror");
$fwrite(g,"%02x\n",word);$fflush(g);received=received+1;
if(received>target) $fatal(1,"extra byte");
end
initial begin #3000000000;$fatal(1,"timeout");end
initial forever begin #1000000;$display("checkpoint time=%0t packet=%0d state=%0d in=%0d out=%0d received=%0d target=%0d",$time,packet,dut.state,dut.input_count,dut.output_count,received,target);$fflush();end
endmodule
