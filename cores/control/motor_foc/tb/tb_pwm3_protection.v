`timescale 1ns/1ps
module tb_pwm3_protection;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,enable=0,fault_n=1,clear=0;reg [15:0] dead=2;
wire [3:0] raw;wire [2:0] hi,lo;wire latched,error;
pwm_gen #(.PERIOD_D(16),.DUTY_D({16'd0,16'd12,16'd8,16'd4})) source(
 clk,1'b1,rst_n,1'b0,3'd0,16'd0,enable,raw);
pwm3_protection dut(clk,rst_n,enable,fault_n,clear,raw[2:0],dead,hi,lo,latched,error);
integer n;reg [2:0] sampled_raw;reg [2:0] target=0;integer remaining[0:2];
reg [2:0] expected_hi=0,expected_lo=0;integer g;
// Independent cycle model of minimum turn-off interval (D clock periods).
always @(posedge clk)begin
 sampled_raw=raw[2:0];
 if(!rst_n||!enable||latched||error||dead==0)begin
  expected_hi=0;expected_lo=0;target=~sampled_raw;
  for(g=0;g<3;g=g+1)remaining[g]=0;
 end else for(g=0;g<3;g=g+1)begin
  if(sampled_raw[g]!=target[g])begin target[g]=sampled_raw[g];remaining[g]=dead;end
  if(remaining[g]>0)begin expected_hi[g]=0;expected_lo[g]=0;remaining[g]=remaining[g]-1;end
  else begin expected_hi[g]=target[g];expected_lo[g]=!target[g];end
 end
 #1;
 if((hi&lo)!=0)$fatal(1,"shoot-through");
 if(rst_n&&enable&&!latched&&!error&&dead!=0&&{hi,lo}!=={expected_hi,expected_lo})$fatal(1,"dead-time mismatch");
 $display("GATES %0d %0d %0d %0d",sampled_raw,hi,lo,latched);
end
task tick;begin @(negedge clk);end endtask
initial begin
 repeat(3)tick;rst_n=1;repeat(3)tick;
 if(!latched||hi||lo)$fatal(1,"reset must require explicit clear");
 clear=1;repeat(2)tick;clear=0;enable=1;repeat(100)tick;
 // Sub-clock fault pulse must shut gates immediately and remain latched.
 #2;fault_n=0;#1;if(hi||lo)$fatal(1,"fault shutdown latency");
 #1;fault_n=1;repeat(4)tick;if(!latched||hi||lo)$fatal(1,"fault not retained");
 clear=1;repeat(3)tick;if(!latched)$fatal(1,"clear while enabled");
 enable=0;repeat(2)tick;clear=0;enable=1;repeat(100)tick;
 dead=0;#1;if(hi||lo)$fatal(1,"zero dead-time not gated");repeat(3)tick;
 dead=3;repeat(3)tick;if(!error||hi||lo)$fatal(1,"configuration error not sticky");
 enable=0;clear=1;repeat(2)tick;clear=0;enable=1;repeat(100)tick;
 $display("PASS PWM3 protection deadtime/fault/clear/config/recovery");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
