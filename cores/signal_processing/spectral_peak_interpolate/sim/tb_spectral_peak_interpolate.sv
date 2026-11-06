`timescale 1ns/1ps
module tb_spectral_peak_interpolate;
 parameter integer MAX_LOG2N=8,TAG_W=8,IQ=0;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,s_valid=0,m_ready=0;
 reg [31:0] c_log2n,c_low,c_high,c_min_power,s_data;
 reg [TAG_W-1:0] c_tag;
 reg s_last,s_invalid;
 wire c_ready,s_ready,m_valid,m_interp_valid;
 wire [2:0] m_status;wire [TAG_W-1:0] m_tag;
 wire [31:0] m_log2n,m_low,m_high,m_min_power,m_peak_index,m_left,m_center,m_right,m_bin_q16;
 wire [12:0] m_received;wire signed [33:0] m_curvature;wire signed [17:0] m_offset_q16;
 wire [3:0] dut_state;
 generate if(IQ)begin:iq_dut
  iq_spectral_peak_interpolate #(.MAX_LOG2N(MAX_LOG2N),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_log2n(c_log2n),.c_low(c_low),.c_high(c_high),
   .c_min_power(c_min_power),.c_tag(c_tag),.s_valid(s_valid),.s_ready(s_ready),.s_iq(s_data),.s_last(s_last),.s_invalid(s_invalid),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_log2n(m_log2n),.m_low(m_low),.m_high(m_high),
   .m_min_power(m_min_power),.m_received(m_received),.m_peak_index(m_peak_index),.m_left(m_left),.m_center(m_center),
   .m_right(m_right),.m_curvature(m_curvature),.m_offset_q16(m_offset_q16),.m_bin_q16(m_bin_q16),.m_interp_valid(m_interp_valid));
  assign dut_state=dut.instrument.state;
 end else begin:power_dut
  spectral_peak_interpolate #(.MAX_LOG2N(MAX_LOG2N),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_log2n(c_log2n),.c_low(c_low),.c_high(c_high),
   .c_min_power(c_min_power),.c_tag(c_tag),.s_valid(s_valid),.s_ready(s_ready),.s_power(s_data),.s_last(s_last),.s_invalid(s_invalid),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_log2n(m_log2n),.m_low(m_low),.m_high(m_high),
   .m_min_power(m_min_power),.m_received(m_received),.m_peak_index(m_peak_index),.m_left(m_left),.m_center(m_center),
   .m_right(m_right),.m_curvature(m_curvature),.m_offset_q16(m_offset_q16),.m_bin_q16(m_bin_q16),.m_interp_valid(m_interp_valid));
  assign dut_state=dut.state;
 end endgenerate
 integer fd,rc,total,case_no,j,target,cycles;
 integer supplied,ex_status,ex_received,ex_valid;
 reg [31:0] logn,low,high,threshold,tag_value,ex_index,ex_left,ex_center,ex_right,ex_bin;
 reg signed [63:0] ex_curve,ex_offset;
 reg [31:0] data[0:4095];integer lasts[0:4095],invalids[0:4095];
 integer results=0,holds=0,cancellations=0,recoveries=0,consecutive_fires=0;
 reg previous_fire=0;
 reg [1023:0] filename,tail_token;
 wire [356+TAG_W:0] bundle={m_status,m_tag,m_log2n,m_low,m_high,m_min_power,m_received,
  m_peak_index,m_left,m_center,m_right,m_curvature,m_offset_q16,m_bin_q16,m_interp_valid};
 reg [356+TAG_W:0] saved;
 reg input_stalled=0,command_stalled=0;
 reg [33:0] held_input;
 reg [127+TAG_W:0] held_command;
 always @(posedge clk)begin
  if(rst)begin input_stalled<=0;command_stalled<=0;previous_fire<=0;end
  else begin
   if(input_stalled && (!s_valid || {s_data,s_last,s_invalid}!==held_input))$fatal(1,"input source changed under stall");
   if(command_stalled && (!c_valid || {c_log2n,c_low,c_high,c_min_power,c_tag}!==held_command))$fatal(1,"command source changed under stall");
   input_stalled<=s_valid && !s_ready;held_input<={s_data,s_last,s_invalid};
   command_stalled<=c_valid && !c_ready;held_command<={c_log2n,c_low,c_high,c_min_power,c_tag};
   if(previous_fire && s_valid && s_ready)consecutive_fires=consecutive_fires+1;
   previous_fire<=s_valid && s_ready;
  end
 end
 task reset_now;begin
  rst=1;c_valid=0;s_valid=0;m_ready=0;
  repeat(3)@(negedge clk);rst=0;#1;
  if(!c_ready || m_valid || s_ready)$fatal(1,"reset interface");
 end endtask
 task load_frame;begin
  rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
   logn,low,high,threshold,tag_value,supplied,ex_status,ex_received,ex_index,ex_left,ex_center,ex_right,ex_curve,ex_offset,ex_bin,ex_valid);
  if(rc!=16)$fatal(1,"header case=%0d rc=%0d",case_no,rc);
  for(j=0;j<supplied;j=j+1)begin
   rc=$fscanf(fd,"%h %d %d\n",data[j],lasts[j],invalids[j]);if(rc!=3)$fatal(1,"sample file");
  end
 end endtask
 task command;begin
  @(negedge clk);c_valid=1;c_log2n=logn;c_low=low;c_high=high;c_min_power=threshold;c_tag=tag_value;
  @(posedge clk);while(!c_ready)@(posedge clk);
  @(negedge clk);c_valid=0;
  // Captured command fields may change while valid is low.
  c_log2n=32'hffffffff;c_low=0;c_high=0;c_min_power=0;c_tag=0;
 end endtask
 task send_one(input integer k);begin
  if(k%5==2)begin @(negedge clk);s_valid=0;end
  s_valid=1;s_data=data[k];s_last=lasts[k];s_invalid=invalids[k];
  @(posedge clk);while(!s_ready)@(posedge clk);
  @(negedge clk);s_valid=0;
 end endtask
 task send_all;integer k;begin for(k=0;k<supplied;k=k+1)send_one(k);end endtask
 task response;integer h;begin
  cycles=0;
  while(!m_valid)begin @(negedge clk);cycles=cycles+1;if(cycles>5000)$fatal(1,"response watchdog");end
  #1;
  if(m_status!==ex_status[2:0] || m_tag!==tag_value[TAG_W-1:0] || m_log2n!==logn || m_low!==low ||
     m_high!==high || m_min_power!==threshold || m_received!==ex_received[12:0] ||
     m_peak_index!==ex_index || m_left!==ex_left || m_center!==ex_center || m_right!==ex_right ||
     $signed(m_curvature)!==ex_curve || $signed(m_offset_q16)!==ex_offset || m_bin_q16!==ex_bin || m_interp_valid!==ex_valid[0])
   $fatal(1,"record case=%0d status=%0d index=%0d LCR=%0d,%0d,%0d curve=%0d offset=%0d bin=%0d valid=%0d",case_no,m_status,m_peak_index,m_left,m_center,m_right,m_curvature,m_offset_q16,m_bin_q16,m_interp_valid);
  saved=bundle;
  for(h=0;h<4;h=h+1)begin
   @(negedge clk);#1;
   if(!m_valid || bundle!==saved || c_ready || s_ready)$fatal(1,"output hold");
   holds=holds+1;
  end
  m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;results=results+1;
 end endtask
 task cancel_at(input integer wanted);integer k,guard;begin
  command();
  if(wanted==1)begin
   if(dut_state!=1)$fatal(1,"CONFIG not live");
  end else if(wanted==2)begin
   while(dut_state!=2)@(negedge clk);
  end else if(wanted==14)begin
   send_one(0);
   if(dut_state!=2)$fatal(1,"partial load not live");
  end else begin
   send_all();guard=0;
   while(dut_state!=wanted)begin
    @(negedge clk);guard=guard+1;if(guard>500)$fatal(1,"cancel state missing %0d actual %0d",wanted,dut_state);
   end
  end
  reset_now();cancellations=cancellations+1;
  command();send_all();response();recoveries=recoveries+1;
 end endtask
 initial begin
  if(!$value$plusargs("VECTORS=%s",filename))$fatal(1,"VECTORS required");
  fd=$fopen(filename,"r");if(!fd)$fatal(1,"open vector");
  rc=$fscanf(fd,"%d\n",total);if(rc!=1 || total!=32)$fatal(1,"case count");
  reset_now();case_no=0;load_frame();
  for(target=1;target<=14;target=target+1)cancel_at(target);
  command();send_all();response();
  for(case_no=1;case_no<total;case_no=case_no+1)begin load_frame();command();send_all();response();end
  // The shared loader is used by both power and actual I/Q entry points.
  rc=$fscanf(fd,"%s",tail_token);
  if((rc!=0 && rc!=-1) || !$feof(fd))$fatal(1,"extra vector token or incomplete EOF");
  $fclose(fd);
  if(results!=46 || holds!=184 || cancellations!=14 || recoveries!=14 || consecutive_fires<=0)$fatal(1,"counters");
  $display("CONSECUTIVE_FIRES count=%0d",consecutive_fires);
  $display("SIM cases=32 results=%0d holds=%0d cancellations=%0d recoveries=%0d continuous=1",results,holds,cancellations,recoveries);
  $finish;
 end
 initial begin #10000000;$fatal(1,"global watchdog");end
endmodule
