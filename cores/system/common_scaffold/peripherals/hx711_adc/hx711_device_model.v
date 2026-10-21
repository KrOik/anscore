`timescale 1ns/1ps
// Independent pin model with delayed data, asynchronous ready and >60us power-down.
module hx711_device_model(input wire pd_sck,suppress_ready,output reg dout);
 integer pulses=0,mode=0,conversion_index=0;reg ready=0,asleep=0;
 reg[23:0]held;time last_rise=0,last_fall=0,ready_at=0,deadline=0,preceding_low=0;
 integer conversions=0,normal_pulses=0,powerdowns=0;time max_high=0;
 function[23:0]sample_value;
 input integer m,n;reg[23:0]base;
 begin case(n%6)0:base=24'h800000;1:base=24'h7fffff;2:base=24'hffffff;3:base=0;4:base=24'h123456;default:base=24'hedcbaa;endcase
 sample_value=base^(m*24'h010101);end endfunction
 initial begin dout=1;held=0;deadline=64'h7fffffffffffffff;end
 always #17 begin
  if(pd_sck&&$time-last_rise>60000&&!asleep)begin asleep=1;dout=1;ready=0;pulses=0;mode=0;conversion_index=0;powerdowns=powerdowns+1;end
  if(suppress_ready&&!asleep&&pulses==0)begin dout=1;ready=0;deadline=$time+20037;end
  if(!pd_sck&&!asleep&&!ready&&!suppress_ready&&$time>=deadline)begin
   if(pulses>=25)begin if(pulses>27)$fatal(1,"too many selection pulses");mode=pulses-25;end
   else if(pulses!=0)$fatal(1,"incomplete data burst resumed conversion");
   held=sample_value(mode,conversion_index);conversion_index=conversion_index+1;
   ready=1;pulses=0;dout=0;ready_at=$time;conversions=conversions+1;
  end
 end
 always @(posedge pd_sck)begin
  last_rise=$time;preceding_low=$time-last_fall;
  if(!asleep)begin
   if(pulses==0&&ready)begin if($time-ready_at<100)$fatal(1,"T1 ready guard too short");ready=0;deadline=64'h7fffffffffffffff;end
   pulses=pulses+1;
   if(pulses<=24)dout<=#80 held[24-pulses];else dout<=#80 1;
  end
 end
 always @(negedge pd_sck)begin
  last_fall=$time;
  if(asleep)begin asleep=0;ready=0;pulses=0;mode=0;dout=1;deadline=$time+20037;end
  else begin
   if($time-last_rise<200||$time-last_rise>=50000)$fatal(1,"unsafe normal SCK high %0t",$time-last_rise);
   if(preceding_low<200)$fatal(1,"T4 low too short");
   if($time-last_rise>max_high)max_high=$time-last_rise;
   normal_pulses=normal_pulses+1;
   if(pulses>=25)deadline=$time+20037;
  end
 end
endmodule
