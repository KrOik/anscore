`timescale 1ns/1ps
module tb_cic_pipeline;
parameter RATE=8,STAGES=3,ACC_W=17;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,sl=0,mr=0;reg signed [7:0] sd=0;
wire sr,mv,ml;wire signed [ACC_W-1:0] md;
cip_dsp_cic_decimator #(.DATA_W(8),.RATE(RATE),.STAGES(STAGES),.ACC_W(ACC_W)) dut(clk,rst_n,ce,sd,sv,sl,sr,md,mv,ml,mr);
reg signed [ACC_W-1:0] integ[0:STAGES-1],delay[0:STAGES-1],values[0:8191];
reg lasts[0:8191];reg signed [ACC_W-1:0] value,prior;
integer cycle,i,head=0,tail=0,count=0,accepted=0,checked=0,resets=0;
reg took_source;
reg held=0;reg signed [ACC_W-1:0] held_data;reg held_last;
reg [31:0] rng=32'h1234abcd;
task reference_reset;begin head=0;tail=0;count=0;for(i=0;i<STAGES;i=i+1)begin integ[i]=0;delay[i]=0;end end endtask
initial begin
 reference_reset;repeat(2)@(negedge clk);rst_n=1;
 for(cycle=0;cycle<3500;cycle=cycle+1)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  ce=cycle>=3300 || cycle%7!=2;mr=cycle>=3300 || cycle%9>2;
  if(!sv && cycle<3200 && rng[2:0]!=0)begin sv=1;sd=rng[15:8];sl=accepted%19==18;end
  if(cycle==307 || cycle==1401)begin rst_n=0;sv=0;held=0;reference_reset;resets=resets+1;end
  else rst_n=1;
  #1;
  if(held && (!mv || md!==held_data || ml!==held_last))$fatal(1,"stall stability");
  if(rst_n && ce)begin
   if(mv && mr)begin
    if(head>=tail || md!==values[head] || ml!==lasts[head])$fatal(1,"numeric %0d got %0d expected %0d",checked,md,values[head]);
    head=head+1;checked=checked+1;
   end
   if(sv && sr)begin
    value=sd;
    for(i=0;i<STAGES;i=i+1)begin integ[i]=integ[i]+value;value=integ[i];end
    count=count+1;
    if(count==RATE || sl)begin
     for(i=0;i<STAGES;i=i+1)begin prior=value;value=value-delay[i];delay[i]=prior;end
     values[tail]=value;lasts[tail]=sl;tail=tail+1;count=0;
    end
    if(sl)begin for(i=0;i<STAGES;i=i+1)begin integ[i]=0;delay[i]=0;end count=0;end
    accepted=accepted+1;
   end
  end
  held=rst_n && mv && !(ce && mr);held_data=md;held_last=ml;
  @(posedge clk);#1;if(rst_n && ce && sv && sr)begin end
  @(negedge clk);
  // Derive the source handshake from pre-edge readiness sampled separately.
  if(took_source)sv=0;
 end
 if(head!=tail || mv)$fatal(1,"drain mismatch");
 $display("CIC_PIPELINE PASS rate=%0d stages=%0d width=%0d accepted=%0d outputs=%0d resets=%0d",RATE,STAGES,ACC_W,accepted,checked,resets);$finish;
end
always @(posedge clk)took_source=rst_n && ce && sv && sr;
initial begin #1000000;$fatal(1,"timeout");end
endmodule
