// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_raw_directional_defect_repair;
 parameter WIDTH=7,HEIGHT=7,BITS=10,TAG_W=7,EXAMPLE=0;
 localparam N=WIDTH*HEIGHT,PAY=3*BITS;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_enable=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,d_ready=0;
 reg [BITS-1:0] c_base_threshold=0,s_data=0;
 reg [1:0] c_gradient_shift=0,c_pattern=0;
 reg [TAG_W-1:0] c_tag=0;
 wire c_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_repaired,d_valid,busy;
 wire [1:0] m_direction;
 wire [PAY-1:0] m_payload;
 wire [2:0] d_error;
 wire [TAG_W-1:0] d_tag;
 wire [16:0] d_repaired;
 generate if(EXAMPLE==0)begin: core
  wire [BITS-1:0] raw;
  wire [1:0] error;
  raw_directional_defect_repair #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_enable(c_enable),
   .c_base_threshold(c_base_threshold),.c_gradient_shift(c_gradient_shift),.c_tag(c_tag),
   .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
   .m_data(raw),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
   .m_repaired(m_repaired),.m_direction(m_direction),.d_valid(d_valid),.d_ready(d_ready),
   .d_error(error),.d_tag(d_tag),.d_repaired(d_repaired),.busy(busy));
  assign m_payload={{(2*BITS){1'b0}},raw};assign d_error={1'b0,error};
 end else begin: composition
  directional_bayer_rgb #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_enable(c_enable),
   .c_base_threshold(c_base_threshold),.c_gradient_shift(c_gradient_shift),.c_pattern(c_pattern),.c_tag(c_tag),
   .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
   .m_rgb(m_payload),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
   .d_valid(d_valid),.d_ready(d_ready),.d_error(d_error),.d_tag(d_tag),.d_repaired(d_repaired),.busy(busy));
  assign m_repaired=0;assign m_direction=0;
 end endgenerate
 reg [BITS-1:0] source[0:N-1];
 reg [PAY-1:0] expected[0:N-1];
 reg expected_repair[0:N-1];reg [1:0] expected_direction[0:N-1];
 integer total_cases,total_pixels,pixel_checks=0,reset_checks=0,holds=0,done_holds=0;
 integer fd,rc,cases_in_file,pixels_in_frame,pixels_in_file,ci,j;
 integer en,base,shift,tag,pattern,fault,repaired,rv0,rv1,rv2,rv3;
 string vector_path;
 task start_command;
 input integer enable_arg,base_arg,shift_arg,tag_arg,pattern_arg;
 begin
  @(negedge clk);c_enable=enable_arg;c_base_threshold=base_arg;c_gradient_shift=shift_arg;
  c_tag=tag_arg;c_pattern=pattern_arg;c_valid=1;
  do begin @(posedge clk);end while(!c_ready);
  @(negedge clk);c_valid=0;
 end endtask
 task reset_now;
 begin
  @(negedge clk);rst=1;c_valid=0;s_valid=0;m_ready=0;d_ready=0;
  #1;if(c_ready||s_ready||m_valid||d_valid||busy)$fatal(1,"reset did not mask public interface");
  repeat(2)@(posedge clk);
  @(negedge clk);rst=0;
  repeat(4)begin @(posedge clk);if(m_valid||d_valid||busy)$fatal(1,"stale work after reset");end
  reset_checks=reset_checks+1;
 end endtask
 task run_frame;
 input integer check_values,fault_arg,tag_arg,repair_arg,stop_mode;
 integer sent,received,cycle,first_hold,last_hold,done_pause;
 reg input_held,output_held,done_held,finished;
 reg [PAY+5:0] output_snapshot;
 reg [TAG_W+19:0] done_snapshot;
 begin
  sent=0;received=0;cycle=0;first_hold=0;last_hold=0;done_pause=0;
  input_held=0;output_held=0;done_held=0;finished=0;
  while(!finished)begin
   @(negedge clk);
   s_valid=(sent<N)&&(input_held||(cycle%7!=2));
   if(sent<N)begin
    s_data=source[sent];s_sof=(sent==0);s_eol=(sent%WIDTH==WIDTH-1);s_last=(sent==N-1);
    if(fault_arg==1&&sent==0)s_sof=!s_sof;
    if(fault_arg==2&&sent==N/2)s_eol=!s_eol;
    if(fault_arg==3&&sent==N-1)s_last=!s_last;
   end
   m_ready=(cycle%13>=3);
   if(m_valid&&received==0&&first_hold<3)m_ready=0;
   if(m_valid&&received==N-1&&last_hold<4)m_ready=0;
   d_ready=(done_pause>=4)&&(stop_mode!=2);
   // Live pins can change without changing the owned command snapshot.
   c_enable=cycle[0];c_base_threshold=cycle;c_gradient_shift=cycle;c_pattern=cycle;c_tag=~tag_arg;
   @(posedge clk);
   if(c_ready)$fatal(1,"command reopened before DONE retirement");
   if(output_held&&(!m_valid||{m_payload,m_repaired,m_direction,m_sof,m_eol,m_last}!==output_snapshot))
    $fatal(1,"stalled output changed");
   if(done_held&&(!d_valid||{d_error,d_tag,d_repaired}!==done_snapshot))$fatal(1,"stalled DONE changed");
   output_held=m_valid&&!m_ready;
   if(output_held)begin
    holds=holds+1;output_snapshot={m_payload,m_repaired,m_direction,m_sof,m_eol,m_last};
    if(received==0)first_hold=first_hold+1;
    if(received==N-1)last_hold=last_hold+1;
   end
   done_held=d_valid&&!d_ready;
   if(done_held)begin done_holds=done_holds+1;done_snapshot={d_error,d_tag,d_repaired};done_pause=done_pause+1;end
   input_held=s_valid&&!s_ready;
   if(s_valid&&s_ready)sent=sent+1;
   if(m_valid&&m_ready)begin
    if(received>=N)$fatal(1,"extra output");
    if(m_sof!==(received==0)||m_eol!==(received%WIDTH==WIDTH-1)||m_last!==(received==N-1))
     $fatal(1,"wrong regenerated output markers");
    if(check_values)begin
     if(m_payload!==expected[received]||m_repaired!==expected_repair[received]||m_direction!==expected_direction[received])
      $fatal(1,"numeric mismatch case=%0d pixel=%0d got=%0d expected=%0d repaired=%0d dir=%0d",ci,received,m_payload,expected[received],m_repaired,m_direction);
     pixel_checks=pixel_checks+1;
    end else if(m_payload!==0)$fatal(1,"zero-frame reset probe was contaminated");
    received=received+1;
   end
   if(d_valid)begin
    if(sent!=N||received!=N)$fatal(1,"completion before full input/output retirement");
    if(d_error!==(fault_arg!=0?3'd1:3'd0)||d_tag!==TAG_W'(tag_arg)||d_repaired!==repair_arg)
     $fatal(1,"wrong completion metadata error=%0d tag=%0h repaired=%0d expected=%0d",d_error,d_tag,d_repaired,repair_arg);
    if(d_ready)finished=1;
   end
   if(stop_mode==1&&m_valid)finished=1;
   if(stop_mode==2&&d_valid&&done_pause>=2)finished=1;
   cycle=cycle+1;
   if(cycle>30*N+10000)$fatal(1,"finite frame watchdog");
  end
  if(stop_mode==0)begin @(negedge clk);s_valid=0;m_ready=0;d_ready=0;end
 end endtask
 initial begin
  for(j=0;j<N;j=j+1)begin source[j]=0;expected[j]=0;expected_repair[j]=0;expected_direction[j]=0;end
  repeat(3)@(posedge clk);@(negedge clk);rst=0;
  // Abort after an admitted input, with first output held, and with DONE held.
  start_command(1,0,0,1,0);
  @(negedge clk);s_valid=1;s_data=0;s_sof=1;s_eol=(WIDTH==1);s_last=(N==1);
  do begin @(posedge clk);end while(!s_ready);
  reset_now();
  start_command(1,0,0,1,0);run_frame(0,0,1,0,1);reset_now();
  start_command(1,0,0,1,0);run_frame(0,0,1,0,2);reset_now();
  if(!$value$plusargs("VECTORS=%s",vector_path))$fatal(1,"missing vector file");
  fd=$fopen(vector_path,"r");if(fd==0)$fatal(1,"cannot open vectors");
  rc=$fscanf(fd,"%d %d %d\n",cases_in_file,pixels_in_frame,pixels_in_file);
  if(rc!=3||pixels_in_frame!=N||pixels_in_file!=cases_in_file*N)$fatal(1,"vector header");
  for(ci=0;ci<cases_in_file;ci=ci+1)begin
   rc=$fscanf(fd,"%d %d %d %d %d %d %d\n",en,base,shift,tag,pattern,fault,repaired);
   if(rc!=7)$fatal(1,"case header");
   for(j=0;j<N;j=j+1)begin
    rc=$fscanf(fd,"%d %d %d %d\n",rv0,rv1,rv2,rv3);
    if(rc!=4)$fatal(1,"vector row");
    source[j]=rv0;expected[j]=rv1;expected_repair[j]=rv2;expected_direction[j]=rv3;
   end
   start_command(en,base,shift,tag,pattern);run_frame(1,fault,tag,repaired,0);
   @(posedge clk);#1;if(busy||m_valid||d_valid)$fatal(1,"retired epoch left visible work");
  end
  rc=$fscanf(fd,"%d",rv0);if(rc!=-1)$fatal(1,"trailing vector rows");$fclose(fd);
  if(pixel_checks!=pixels_in_file||reset_checks!=3||holds==0||done_holds==0)$fatal(1,"coverage counters");
  $display("B48_RUN cases=%0d pixels=%0d reset_checks=%0d",cases_in_file,pixel_checks,reset_checks);
  $finish;
 end
endmodule
