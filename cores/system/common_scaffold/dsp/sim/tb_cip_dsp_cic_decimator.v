`timescale 1ns/1ps
module tb_cip_dsp_cic_decimator;
parameter RATE=8, STAGES=3, ACC_W=17;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,sl=0,mr=0;reg signed [7:0] sd=0;
wire sr,mv,ml;wire signed [ACC_W-1:0] md;
cip_dsp_cic_decimator #(.DATA_W(8),.RATE(RATE),.STAGES(STAGES),.ACC_W(ACC_W)) dut
 (clk,rst_n,ce,sd,sv,sl,sr,md,mv,ml,mr);
reg [1023:0] input_path,expected_path;
integer inputs=0,outputs=0,cycles=0,a,b,c,d,e,f,fi,fo,code,emit,gold,last_gold;
integer head=0,tail=0,wait_cycles,resets=0,cancelled=0,drain;
reg signed [ACC_W-1:0] queue_data[0:8191];reg queue_last[0:8191];
reg held=0;reg signed [ACC_W-1:0] held_data;reg held_last,took;
task cycle_step;
begin
 #1;
 if(held && rst_n && (!mv || md!==held_data || ml!==held_last))$fatal(1,"unstable stalled/CE-disabled output");
 took=rst_n && ce && sv && sr;
 if(rst_n && ce && mv && mr)begin
  if(head>=tail)$fatal(1,"unexpected output before reference checkpoint");
  if(md!==queue_data[head] || ml!==queue_last[head])$fatal(1,"output %0d got %0d/%b expected %0d/%b",outputs,md,ml,queue_data[head],queue_last[head]);
  head=head+1;outputs=outputs+1;
 end
 if(took)begin
  inputs=inputs+1;
  if(emit)begin
   if(tail>=8192)$fatal(1,"scoreboard overflow");
   queue_data[tail]=gold;queue_last[tail]=last_gold;tail=tail+1;
  end
 end
 held=rst_n && mv && !(ce && mr);held_data=md;held_last=ml;
 @(posedge clk);#1;@(negedge clk);cycles=cycles+1;
end
endtask
initial begin
 if(!$value$plusargs("input=%s",input_path))$fatal(1,"input path");
 if(!$value$plusargs("expected=%s",expected_path))$fatal(1,"expected path");
 fi=$fopen(input_path,"r");fo=$fopen(expected_path,"r");if(!fi || !fo)$fatal(1,"fixture missing");
 repeat(2)@(negedge clk);
 while(!$feof(fi))begin
  code=$fscanf(fi,"%d %d %d %d %d %d\n",a,b,c,d,e,f);if(code!=6)$fatal(1,"bad stimulus");
  code=$fscanf(fo,"%d %d %d\n",emit,gold,last_gold);if(code!=3)$fatal(1,"missing logical reference");
  ce=a;sv=b;sd=c;sl=d;mr=e;rst_n=f;
  if(!rst_n)begin cancelled=cancelled+tail-head;head=0;tail=0;held=0;resets=resets+1;end
  wait_cycles=0;
  cycle_step;
  // Hold data/last/valid until the DUT actually accepts. CE and sink readiness
  // vary independently and guarantee progress; no fixed DUT latency is assumed.
  while(rst_n && sv && !took)begin
   wait_cycles=wait_cycles+1;if(wait_cycles>1000)$fatal(1,"input handshake timeout");
   ce=(wait_cycles%5!=1);mr=(wait_cycles%7>1);cycle_step;
  end
 end
 sv=0;ce=1;mr=1;emit=0;
 for(drain=0;drain<STAGES+10;drain=drain+1)cycle_step;
 if(head!=tail || mv)$fatal(1,"missing output/drain %0d/%0d",head,tail);
 code=$fscanf(fo,"%d %d %d\n",emit,gold,last_gold);if(code==3)$fatal(1,"extra reference record");
 if(inputs<1000 || outputs<100 || resets<3)$fatal(1,"insufficient coverage");
 $display("PASS CIC rate=%0d stages=%0d inputs=%0d outputs=%0d cycles=%0d resets=%0d cancelled=%0d",RATE,STAGES,inputs,outputs,cycles,resets,cancelled);
 $fclose(fi);$fclose(fo);$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
