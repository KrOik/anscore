`timescale 1ns/1ps
module tb_two_rgb;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cmd_valid=0,s_valid=0,s_last=0,m_ready=0,rsp_ready=0,stall=0;
 reg [15:0] cmd_pixels=0;
 reg [7:0] cmd_tag=0;
 reg [47:0] s_rgb=0;
 wire cmd_ready,s_ready,m_valid,m_last,rsp_valid;
 wire [31:0] m_features,rsp_outputs;
 wire [7:0] m_tag,rsp_tag;
 wire [1:0] rsp_error;
 two_rgb_group_projection #(.MAX_PIXELS(64),.TAG_W(8)) dut(.*);
 integer cycles=0,seen=0,expected=0,scored=0,frames=0,holds=0,resets=0,errors=0;
 integer i,fd,rc,p,t,n,extra;
 reg [47:0] samples[0:63];
 reg [31:0] answers[0:63];
 reg [7:0] expected_tag;
 reg scoring=0,held=0;
 reg [40:0] held_payload;
 reg [2047:0] filename;
 always @(negedge clk)m_ready=!stall && cycles%9>2;
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>100000)$fatal(1,"example watchdog");
  if(rst)held=0;
  else begin
   if(held)begin
    if(!m_valid || {m_features,m_last,m_tag}!==held_payload)$fatal(1,"packed output hold");
    holds=holds+1;
   end
   held=m_valid && !m_ready;held_payload={m_features,m_last,m_tag};
   if(m_valid && m_ready)begin
    if(!scoring || seen>=expected || m_features!==answers[seen] ||
      m_last!==(seen==expected-1) || m_tag!==expected_tag)$fatal(1,"packed projection %0d",seen);
    seen=seen+1;scored=scored+1;
   end
   if(m_valid && m_last && rsp_valid)$fatal(1,"completion exposed before packed retirement");
  end
 end
 task reset_all;
 begin
  @(negedge clk);rst=1;cmd_valid=0;s_valid=0;rsp_ready=0;scoring=0;
  repeat(3)@(negedge clk);rst=0;resets=resets+1;@(negedge clk);
 end endtask
 task command(input integer pixels,tag_value);
 begin
  @(negedge clk);cmd_pixels=pixels;cmd_tag=tag_value;expected_tag=tag_value;cmd_valid=1;rsp_ready=0;
  do @(posedge clk);while(!cmd_ready);
  @(negedge clk);cmd_valid=0;
 end endtask
 task pixel(input [47:0] value,input integer last_value);
 begin
  s_rgb=value;s_last=last_value;s_valid=1;
  do @(posedge clk);while(!s_ready);
  @(negedge clk);s_valid=0;
 end endtask
 task completion(input integer err,output_count);
 begin
  while(!rsp_valid)@(negedge clk);
  if(rsp_error!==err || rsp_outputs!==output_count || rsp_tag!==expected_tag)$fatal(1,"example completion");
  repeat(4)begin @(negedge clk);if(!rsp_valid || cmd_ready || s_ready)$fatal(1,"example ownership");end
  rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;scoring=0;
  if(err!=0)errors=errors+1;
 end endtask
 initial begin
  if(!$value$plusargs("VECTORS=%s",filename))$fatal(1,"missing example fixture");
  fd=$fopen(filename,"r");if(!fd)$fatal(1,"example fixture open");
  reset_all();command(0,10);completion(1,0);
  rc=$fscanf(fd,"%d",n);if(rc!=1 || n!=3)$fatal(1,"example header");
  for(t=0;t<n;t=t+1)begin
   rc=$fscanf(fd,"%d %d",p,i);if(rc!=2 || p>64)$fatal(1,"example geometry");
   expected_tag=i;
   for(i=0;i<p;i=i+1)begin
    rc=$fscanf(fd,"%h %h",samples[i],answers[i]);if(rc!=2)$fatal(1,"example fixture row");
   end
   seen=0;expected=p;scoring=1;command(p,31+t);
   for(i=0;i<p;i=i+1)pixel(samples[i],i==p-1);
   completion(0,4*p);if(seen!=p)$fatal(1,"example lost output");frames=frames+1;
  end
  rc=$fscanf(fd,"%d",extra);if(!((rc==0 || rc==-1) && $feof(fd)))$fatal(1,"example suffix");$fclose(fd);
  seen=0;command(2,41);pixel(48'd0,1);completion(3,0);
  seen=0;command(1,42);pixel(48'd0,0);completion(3,0);
  // Reset cancels a live pixel, restarts the fixed resident-weight boot, and recovers.
  command(1,43);pixel(48'h808080808080,1);repeat(2)@(negedge clk);reset_all();
  seen=0;expected=1;answers[0]=0;scoring=1;stall=1;command(1,44);pixel(48'h808080808080,1);
  while(!m_valid)@(negedge clk);
  repeat(5)begin @(negedge clk);if(rsp_valid || cmd_ready)$fatal(1,"pending packed owner");end
  stall=0;completion(0,4);
  if(frames!=3 || scored!=73 || errors!=3 || holds==0 || resets!=2)$fatal(1,"example coverage");
  $display("PASS TWO_RGB frames=%0d scored=%0d errors=%0d resets=%0d held=%0d",frames,scored,errors,resets,holds);
  $finish;
 end
endmodule
