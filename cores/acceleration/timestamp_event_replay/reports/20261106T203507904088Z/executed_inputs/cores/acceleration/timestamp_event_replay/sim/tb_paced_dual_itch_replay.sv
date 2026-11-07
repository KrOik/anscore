`timescale 1ns/1ps
module tb_paced_dual_itch_replay;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,run_enable=1,abort_run=0;
 reg [31:0] c_count=4;reg [47:0] c_step_q16=65536;reg [7:0] c_tag=8'h5a;
 wire c_ready;
 reg [1:0] cfg_valid=0,s_valid=0,s_keep=0,s_last=0;
 wire [1:0] cfg_ready,s_ready;
 reg [159:0] cfg_session={80'h42353046454544303031,80'h42353046454544303030};
 reg [127:0] cfg_next={64'd200,64'd100};
 reg [15:0] s_data=0,s_tag=16'h3231;
 wire [1:0] packet_valid,packet_end;reg [1:0] packet_ready=3;
 wire [7:0] packet_status;wire [159:0] packet_session;
 wire [127:0] packet_sequence,packet_next;wire [31:0] packet_messages,packet_events;
 wire [15:0] packet_tag;
 reg a_valid=0;wire a_ready;reg [2:0] a_op=0;reg [31:0] a_feed=0;
 reg [63:0] a_time=0;reg [7:0] a_tag=0;
 wire z_valid;reg z_ready=1;wire [2:0] z_op;wire [3:0] z_status;
 wire [31:0] z_feed,z_heads;wire z_end,z_head,z_closed,z_has_previous,z_has_watermark;
 wire [63:0] z_previous_time,z_previous_sequence,z_watermark;wire [7:0] z_tag;
 wire m_valid,m_feed;reg m_ready=1;wire [63:0] m_time,m_sequence;
 wire [511:0] m_data;wire [7:0] m_tag;
 wire error_valid,error_feed;reg error_ready=1;wire [3:0] error_status;wire [7:0] error_tag;
 wire merge_faulted,source_fault,d_valid,active,epoch_flush;reg d_ready=0;
 wire [2:0] d_status;wire [31:0] d_received,d_emitted;
 wire [63:0] d_anchor;wire [79:0] d_elapsed_q16;wire [7:0] d_tag;
 reg [7:0] feed0[0:95],feed1[0:95];string feed0_path,feed1_path;
 integer cycle=0,phase=0,seen=0,packets=0,stall_count=0,first_offer=-1;
 integer lane,expected_feed,expected_index;
 reg [3:0] offered_mask=0;
 reg held=0;reg [648:0] hold_event;
 reg held_done=0;reg [218:0] hold_done;
 paced_dual_itch_replay dut(.*);
 function [511:0] payload_for;
  input integer feed,index;
  reg [15:0] locate,tracking;reg [63:0] order;
  reg [31:0] quantity,price;reg [7:0] tag;
  reg sell,last;reg [406:0] packed_value;
  begin
   locate=11+feed;tracking=20+index;order=10+feed+2*index;
   quantity=100+order;price=1000+order;tag=8'h31+feed;sell=feed!=0;last=index==1;
   packed_value={8'h41,locate,tracking,order,64'd0,quantity,price,64'h5445535420202020,
    32'd0,64'd0,sell,1'b0,1'b1,1'b1,1'b0,1'b0,last,tag};
   payload_for={{105{1'b0}},packed_value};
  end
 endfunction
 always @(negedge clk)begin
  if(phase==3)m_ready=0;
  else if(phase==1 && seen==1 && m_valid && stall_count<8)begin
   m_ready=0;stall_count=stall_count+1;
  end else m_ready=1;
 end
 always @(posedge clk)begin
  cycle=cycle+1;
  if(rst)begin
   seen=0;packets=0;stall_count=0;first_offer=-1;offered_mask=0;held=0;held_done=0;
  end else begin
   if(held && !epoch_flush && (!m_valid || {m_feed,m_time,m_sequence,m_data,m_tag}!==hold_event))
    $fatal(1,"wrapper held output changed cycle%0d",cycle);
   if(held_done && (!d_valid || {d_status,d_received,d_emitted,d_anchor,d_elapsed_q16,d_tag}!==hold_done))
    $fatal(1,"wrapper held completion changed");
   held=m_valid && !m_ready;
   hold_event={m_feed,m_time,m_sequence,m_data,m_tag};
   held_done=d_valid && !d_ready;
   hold_done={d_status,d_received,d_emitted,d_anchor,d_elapsed_q16,d_tag};
   if(phase==1)begin
    if(source_fault || error_valid || merge_faulted)$fatal(1,"unexpected real source fault");
    for(lane=0;lane<2;lane=lane+1)if(packet_valid[lane] && packet_ready[lane])begin
     if(packet_status[lane*4+:4]!=0 || packet_messages[lane*16+:16]!=2 ||
        packet_events[lane*16+:16]!=2 || packet_next[lane*64+:64]!=(lane==0?64'd102:64'd202))
      $fatal(1,"packet result mismatch feed%0d",lane);
     packets=packets+1;
    end
    if(m_valid)begin
     if(seen>=4)$fatal(1,"extra paced event");
     expected_feed=seen%2;expected_index=seen/2;
     if(m_feed!==expected_feed[0] || m_time!==(64'd100000+seen*1000) ||
        m_sequence!==((expected_feed==0?64'd100:64'd200)+expected_index) ||
        m_data!==payload_for(expected_feed,expected_index) || m_tag!==8'h5a)
      $fatal(1,"paced event fields index%0d cycle%0d",seen,cycle);
     if(!offered_mask[seen])begin
      if(seen==0)first_offer=cycle;
      else if(cycle!=first_offer+seen*1000)$fatal(1,"timestamp gap not preserved index%0d got%0d expected%0d",
       seen,cycle,first_offer+seen*1000);
      offered_mask[seen]=1;
     end
     if(m_ready)seen=seen+1;
    end
   end
   if(phase==2 && m_valid)$fatal(1,"bad-session packet emitted an event");
  end
 end
 task reset_epoch;
  begin
   @(negedge clk);rst=1;phase=0;c_valid=0;cfg_valid=0;s_valid=0;s_keep=0;s_last=0;
   a_valid=0;abort_run=0;d_ready=0;run_enable=1;
   repeat(3)@(posedge clk);
   @(negedge clk);rst=0;
  end
 endtask
 task configure;
  reg [1:0] take;
  begin
   @(negedge clk);cfg_valid=3;
   while(cfg_valid!=0)begin
    @(posedge clk);take=cfg_valid & cfg_ready;
    @(negedge clk);cfg_valid=cfg_valid & ~take;
   end
  end
 endtask
 task arm;
  input [31:0] count;
  begin
   @(negedge clk);c_count=count;c_step_q16=65536;c_tag=8'h5a;c_valid=1;
   begin:wait_command
    forever begin @(posedge clk);if(c_ready)disable wait_command;end
   end
   @(negedge clk);c_valid=0;
  end
 endtask
 task automatic send_packet;
  input integer feed;input bad_session;
  integer i;reg [7:0] byte_value;
  begin
   for(i=0;i<96;i=i+1)begin
    byte_value=feed==0?feed0[i]:feed1[i];
    if(bad_session && i==0)byte_value=byte_value^8'h01;
    @(negedge clk);s_valid[feed]=1;s_keep[feed]=1;s_last[feed]=i==95;
    s_data[feed*8+:8]=byte_value;
    begin:wait_byte
     forever begin @(posedge clk);if(s_ready[feed])disable wait_byte;end
    end
    @(negedge clk);s_valid[feed]=0;s_keep[feed]=0;s_last[feed]=0;
   end
  end
 endtask
 task close_feed;
  input [31:0] feed;
  begin
   @(negedge clk);a_op=1;a_feed=feed;a_time=0;a_tag=8'hc0+feed;a_valid=1;
   begin:wait_admin
    forever begin @(posedge clk);if(a_ready)disable wait_admin;end
   end
   @(negedge clk);a_valid=0;
   begin:wait_admin_result
    forever begin
     @(posedge clk);
     if(z_valid)begin
      if(z_status!=0 || z_op!=1 || z_feed!=feed || z_tag!=(8'hc0+feed))
       $fatal(1,"EOS result mismatch");
      disable wait_admin_result;
     end
    end
   end
  end
 endtask
 task retire_done;
  input [2:0] status;input [31:0] received,emitted;
  begin
   wait(d_valid);@(negedge clk);
   if(d_status!=status || d_received!=received || d_emitted!=emitted || d_tag!=8'h5a)
    $fatal(1,"wrapper terminal mismatch got%0d recv%0d emit%0d",d_status,d_received,d_emitted);
   repeat(4)@(negedge clk);
   d_ready=1;@(posedge clk);@(negedge clk);d_ready=0;
  end
 endtask
 initial begin
  if(!$value$plusargs("FEED0=%s",feed0_path) || !$value$plusargs("FEED1=%s",feed1_path))
   $fatal(1,"missing packet fixtures");
  $readmemh(feed0_path,feed0);$readmemh(feed1_path,feed1);
  reset_epoch();phase=1;configure();arm(4);
  fork send_packet(0,0);send_packet(1,0);join
  wait(packets==2);close_feed(0);close_feed(1);
  wait(d_valid);@(negedge clk);
  if(seen!=4 || offered_mask!=4'b1111 || stall_count!=8 || d_anchor!=100000)
   $fatal(1,"real merge/pacing closure incomplete");
  retire_done(0,4,4);
  reset_epoch();phase=2;configure();arm(1);send_packet(0,1);
  wait(source_fault);retire_done(4,0,0);
  repeat(4)@(negedge clk);
  c_valid=1;
  repeat(4)begin @(negedge clk);if(c_ready || !source_fault)$fatal(1,"source poison was not sticky");end
  reset_epoch();phase=3;configure();arm(4);
  fork send_packet(0,0);send_packet(1,0);join
  wait(m_valid);repeat(4)@(negedge clk);
  abort_run=1;#1;
  if(!epoch_flush || m_valid || s_ready!=0)$fatal(1,"epoch abort did not expose interface flush");
  @(posedge clk);@(negedge clk);abort_run=0;
  retire_done(4,1,0);
  reset_epoch();
  $display("PASS paced_dual_itch_replay: four timed actual decoded events, held output, source poison, epoch abort");
  $finish;
 end
 initial begin #100000;$fatal(1,"wrapper10000-cycle bound exceeded");end
endmodule
