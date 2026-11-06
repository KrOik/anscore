// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_rgba_sprite_blit;
 parameter W=9,H=6,TW=16,TH=16,T=8;
 reg clk=0,rst=1;always #5 clk=~clk;
 reg c_valid=0,c_flip_x=0,c_flip_y=0;wire c_ready;
 reg [7:0] c_u=0,c_v=0;reg [8:0] c_width=0,c_height=0;
 reg signed [15:0] c_x=0,c_y=0;reg [T-1:0] c_tag=0;
 wire q_valid,s_ready,m_valid,d_valid,busy;reg q_ready=0,s_valid=0,m_ready=0,d_ready=0;
 wire [7:0] q_u,q_v,m_alpha;wire [15:0] q_x,q_y,m_x,m_y;wire [T-1:0] q_tag,d_tag;
 reg [23:0] s_rgb=0;reg [7:0] s_alpha=0;reg s_visible=0;reg [15:0] s_x=0,s_y=0;
 wire [23:0] m_rgb;wire [1:0] d_status;wire [16:0] d_requested,d_written,d_skipped;
 integer cycle=0,commit_remaining=0,q_index=0,s_head=0,m_index=0;
 integer all_queries=0,all_fragments=0,commands=0,done_checks=0,resets=0,holds=0,max_flight=0;
 reg source_stalled=0,q_held=0;reg [T+47:0] q_snapshot;
 wire writes_idle=commit_remaining==0;
 rgba_sprite_blit #(.WIDTH(W),.HEIGHT(H),.TEX_WIDTH(TW),.TEX_HEIGHT(TH),.TAG_W(T)) dut(.*);
 reg [T+67:0] command_data[0:16];reg [T+52:0] done_data[0:16];
 reg [T+47:0] request_data[0:4095];reg [64:0] response_data[0:4095];
 reg [63:0] fragment_data[0:4095];reg [31:0] counts[0:2];integer due[0:4095];
 wire [T+47:0] query_payload={q_tag,q_y,q_x,q_v,q_u};
 wire [T+52:0] done_payload={d_tag,d_status,d_skipped,d_written,d_requested};
 always @(negedge clk)begin
  if(rst)begin q_ready=0;s_valid=0;m_ready=0;end
  else begin
   q_ready=cycle%5!=1;
   m_ready=commit_remaining==0 && cycle%7!=2;
   if(!source_stalled)begin
    s_valid=s_head<q_index && cycle>=due[s_head] && cycle%4!=0;
    if(s_head<q_index){s_y,s_x,s_visible,s_alpha,s_rgb}=response_data[s_head];
   end
  end
 end
 always @(posedge clk)begin
  cycle=cycle+1;if(cycle>100000)$fatal(1,"finite core watchdog");
  if(rst)begin q_index=0;s_head=0;m_index=0;commit_remaining<=0;source_stalled=0;q_held=0;end
  else begin
   if(q_held && (!q_valid || query_payload!==q_snapshot))$fatal(1,"held request changed");
   q_held=q_valid&&!q_ready;q_snapshot=query_payload;
   source_stalled=s_valid&&!s_ready;
   if(commit_remaining>0)commit_remaining<=commit_remaining-1;
   if(q_valid&&q_ready)begin
    if(q_index>=counts[1] || query_payload!==request_data[q_index])$fatal(1,"request %0d got%h expected%h",q_index,query_payload,request_data[q_index]);
    due[q_index]=cycle+3;q_index=q_index+1;all_queries=all_queries+1;
   end
   if(s_valid&&s_ready)s_head=s_head+1;
   if(m_valid&&m_ready)begin
    if(m_index>=counts[2] || {m_y,m_x,m_alpha,m_rgb}!==fragment_data[m_index])$fatal(1,"fragment mismatch");
    m_index=m_index+1;all_fragments=all_fragments+1;commit_remaining<=3;
   end
   if(q_index-s_head>3 || s_head>q_index)$fatal(1,"outstanding capacity");
   if(q_index-s_head>max_flight)max_flight=q_index-s_head;
   if(d_valid && (!writes_idle || q_index!=s_head))$fatal(1,"DONE before all writes committed");
   if(m_valid&&!m_ready)holds=holds+1;
  end
 end
 task reset_here(input integer immediate);
  begin
   if(!immediate)@(negedge clk);
   rst=1;c_valid=0;d_ready=0;s_valid=0;m_ready=0;
   #1;if(c_ready||q_valid||s_ready||m_valid||d_valid||busy)$fatal(1,"reset masks");
   @(posedge clk);#1;@(negedge clk);rst=0;resets=resets+1;
  end
 endtask
 task offer(input integer k);
  begin
   @(negedge clk);{c_tag,c_flip_y,c_flip_x,c_y,c_x,c_height,c_width,c_v,c_u}=command_data[k];c_valid=1;
   @(posedge clk);while(!c_ready)@(posedge clk);commands=commands+1;
   @(negedge clk);c_valid=0;c_u=255;c_v=255;c_width=511;c_height=511;
   c_x=-32768;c_y=32767;c_flip_x=~c_flip_x;c_flip_y=~c_flip_y;c_tag=~c_tag;
  end
 endtask
 task scene(input integer cancel_last);
  integer k,budget;reg [T+52:0] held_done;
  begin
   for(k=0;k<17;k=k+1)begin
    offer(k);budget=0;
    @(posedge clk);while(!d_valid)begin @(posedge clk);budget=budget+1;if(budget>10000)$fatal(1,"blit completion budget");end
    if(done_payload!==done_data[k])$fatal(1,"DONE k%0d got%h expected%h",k,done_payload,done_data[k]);
    if(d_requested==0 && budget>2)$fatal(1,"empty rectangle traversed");
    done_checks=done_checks+1;held_done=done_payload;
    repeat(3)begin @(posedge clk);if(!d_valid || done_payload!==held_done || c_ready || q_valid)$fatal(1,"held DONE ownership");end
    if(k==16)begin
     if(q_index!=counts[1] || m_index!=counts[2] || s_head!=q_index)$fatal(1,"scene accounting");
    end
    if(cancel_last && k==16)reset_here(0);
    else begin @(negedge clk);d_ready=1;@(posedge clk);@(negedge clk);d_ready=0;end
   end
  end
 endtask
 initial begin
  $readmemh("counts.hex",counts);$readmemh("commands.hex",command_data);$readmemh("done.hex",done_data);
  $readmemh("requests.hex",request_data,0,counts[1]-1);$readmemh("responses.hex",response_data,0,counts[1]-1);
  if(counts[2]>0)$readmemh("fragments.hex",fragment_data,0,counts[2]-1);
  reset_here(0);offer(0);reset_here(1);scene(1);scene(0);
  if(commands!=35 || done_checks!=34 || resets!=3 || all_queries!=2*counts[1] || all_fragments!=2*counts[2])$fatal(1,"coverage accounting");
  if(TW>1 && max_flight!=3)$fatal(1,"three outstanding slots not exercised");
  $display("PASS RGBA_BLIT W=%0d H=%0d T=%0d commands=%0d done=%0d queries=%0d fragments=%0d resets=%0d holds=%0d max_flight=%0d",W,H,T,commands,done_checks,all_queries,all_fragments,resets,holds,max_flight);$finish;
 end
endmodule
