`timescale 1ns/1ps
module tb_live_adc_lockin;
 parameter SIN_FILE="",COS_FILE="";
 reg clk=0,rst=0,start=0,cv=0,mr=0,ack=0,allow=1,overflow_mode=0;
 reg [31:0] tuning=0,period=16,id=0,phases=0;
 reg [3:0] log2=8;reg [63:0] amplitudes=0;
 wire ar,cr,sv,sr,mv,done;wire [63:0] samples,oi,oq,amp,first,last;
 wire [255:0] ts;wire [71:0] phase;wire [31:0] oid,generated,accepted,dropped;
 wire [1:0] ae;wire [4:0] error;
 wire sample_ready=allow&&(overflow_mode||sr);
 virtual_adc4 #(.COS_FILE(COS_FILE)) adc(clk,rst,start,ar,tuning,period,log2,amplitudes,phases,
  sv,sample_ready,samples,ts,done,ack,ae,generated,accepted,dropped,1'b0);
 lockin4 #(.SIN_FILE(SIN_FILE),.COS_FILE(COS_FILE)) dut(clk,rst&&!overflow_mode,cv,cr,tuning,period,id,log2,
  64'd0,{4{16'd32768}},sv&&allow&&!overflow_mode,sr,samples,ts,mv,mr,oi,oq,amp,phase,first,last,oid,error);
 always #5 clk=~clk;
 integer run=0,index=0,ticks=0,n;reg [63:0] tick_time[0:4095];
 reg held=0;reg [319:0] held_sample;
 always @(posedge clk)if(rst)begin
  if(start&&ar)begin index=0;ticks=0;end
  if(adc.sample_tick)begin
   tick_time[ticks]=adc.now;
   if(ticks>0&&adc.now-tick_time[ticks-1]!=period)$fatal(1,"physical sample clock period");
   ticks=ticks+1;
  end
  if(held&&(!sv||{samples,ts}!==held_sample))$fatal(1,"ADC offer changed under backpressure");
  held<=sv&&!sample_ready;held_sample<={samples,ts};
  if(sv&&sample_ready&&!overflow_mode)begin
   if(ts[63:0]!=tick_time[index])$fatal(1,"timestamp not physical sample event");
   $display("ADC_SAMPLE run=%0d index=%0d time=%0d data=%016h",run,index,ts[63:0],samples);
   index=index+1;
  end
 end else held<=0;
 task launch;
 begin
  @(negedge clk);start=1;cv=!overflow_mode;
  do @(posedge clk);while(!ar||(!overflow_mode&&!cr));
  @(negedge clk);start=0;cv=0;
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  for(run=0;run<3;run=run+1)begin
   period=run==0?4:run==1?16:37;log2=8;tuning=(run==0?1:run==1?3:7)<<24;id=run;
   case(run)
    0:begin amplitudes={16'd24000,16'd12000,16'd4000,16'd1000};phases={8'd96,8'd192,8'd32,8'd0};end
    1:begin amplitudes={16'd20000,16'd8000,16'd2000,16'd64};phases={8'd224,8'd128,8'd64,8'd16};end
    2:begin amplitudes={16'd28000,16'd16000,16'd5000,16'd500};phases={8'd48,8'd160,8'd80,8'd240};end
   endcase
   launch();wait(mv&&done);
   if(error!=0||ae!=0||generated!=256||accepted!=256||dropped!=0||ticks!=256||index!=256)$fatal(1,"live capture status");
   if(last-first!=255*period)$fatal(1,"live block timestamp span");
   for(n=0;n<4;n=n+1)$display("LIVE_RESULT run=%0d lane=%0d i=%0d q=%0d amplitude=%0d phase=%0d first=%0d last=%0d",
    run,n,$signed(oi[n*16+:16]),$signed(oq[n*16+:16]),amp[n*16+:16],$signed(phase[n*18+:18]),first,last);
   repeat(9)@(negedge clk);mr=1;ack=1;@(negedge clk);mr=0;ack=0;
  end
  // Stop accepting while physical ticks continue: source must hold the old
  // vector,flag and count losses,then terminate after the buffer is drained.
  overflow_mode=1;period=4;log2=4;allow=0;launch();repeat(100)@(negedge clk);
  allow=1;wait(done);
  if(ae!=2||generated!=16||accepted!=1||dropped!=15)$fatal(1,"ADC overflow accounting %0d/%0d/%0d",generated,accepted,dropped);
  @(negedge clk);ack=1;@(negedge clk);ack=0;
  period=3;launch();wait(done);if(ae!=1)$fatal(1,"ADC invalid period");
  $display("PASS live4ADC lockin physicalclock timestamps,cadence,overflow,finite recovery");$finish;
 end
 initial begin #1000000;$fatal(1,"live ADC timeout run=%0d state=%0d gen=%0d accepted=%0d dropped=%0d done=%b allow=%b start=%b",run,adc.state,generated,accepted,dropped,done,allow,start);end
endmodule
