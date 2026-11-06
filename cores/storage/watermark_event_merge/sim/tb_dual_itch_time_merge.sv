`timescale 1ns/1ps
module tb_dual_itch_time_merge;
 localparam TAG_W=8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1;reg [1:0] cfg_valid=0,s_valid=0,s_keep=3,s_last=0,packet_ready=3;
 wire [1:0] cfg_ready,s_ready,packet_valid,packet_end;
 reg [159:0] cfg_session={80'h46454544303030303032,80'h46454544303030303031};
 reg [127:0] cfg_next={64'd100,64'd10};reg [15:0] s_data=0,s_tag=0;
 wire [7:0] packet_status;wire [159:0] packet_session;wire [127:0] packet_sequence,packet_next;
 wire [31:0] packet_messages,packet_events;wire [15:0] packet_tag;
 reg a_valid=0,z_ready=0,m_ready=0,error_ready=0;wire a_ready,z_valid,m_valid,error_valid,faulted;
 reg [2:0] a_op=0;reg [31:0] a_feed=0;reg [63:0] a_time=0;reg [7:0] a_tag=0;
 wire [2:0] z_op;wire [3:0] z_status,error_status;wire [31:0] z_feed,z_heads;
 wire z_end,z_head,z_closed,z_has_previous,z_has_watermark,m_feed,error_feed;
 wire [63:0] z_previous_time,z_previous_sequence,z_watermark,m_time,m_sequence;
 wire [7:0] z_tag,error_tag;wire [511:0] m_data;
 dual_itch_time_merge dut(.*);
 reg [7:0] bytes[0:1][0:57];
 integer cycles=0,packets=0,events=0,admins=0,holds=0,resets=0,futures=0,cancelled=0;
 integer i,j,n,timeout;reg [63:0] packet_expected[0:1];
 reg [511+1+64+64:0] held_event;
 wire [511+1+64+64:0] event_payload={m_feed,m_time,m_sequence,m_data};
 reg admin_held=0;reg [106:0] admin_saved;wire [106:0] admin_payload={a_op,a_feed,a_time,a_tag};
 reg [1:0] byte_held=0;reg [17:0] byte_saved[0:1];
 always @(posedge clk)begin
  cycles<=cycles+1;if(cycles>25000)$fatal(1,"example whole watchdog");
  if(rst)begin admin_held<=0;byte_held<=0;packet_expected[0]<=10;packet_expected[1]<=100;end
  else begin
   if(admin_held && (!a_valid || admin_payload!==admin_saved))$fatal(1,"withdrawn admin future");
   admin_held<=a_valid && !a_ready;if(a_valid && !a_ready)admin_saved<=admin_payload;
   for(integer f=0;f<2;f=f+1)begin
    if(byte_held[f] && (!s_valid[f] || {s_data[f*8+:8],s_keep[f],s_last[f],s_tag[f*8+:8]}!==byte_saved[f]))$fatal(1,"withdrawn packet byte");
    byte_held[f]<=s_valid[f] && !s_ready[f];if(s_valid[f] && !s_ready[f])byte_saved[f]<={s_data[f*8+:8],s_keep[f],s_last[f],s_tag[f*8+:8]};
    if(packet_valid[f] && packet_ready[f])begin
     if(packet_status[f*4+:4]!=0 || packet_session[f*80+:80]!==cfg_session[f*80+:80] || packet_sequence[f*64+:64]!==packet_expected[f] || packet_next[f*64+:64]!==packet_expected[f]+1 || packet_messages[f*16+:16]!=1 || packet_events[f*16+:16]!=1 || packet_end[f])$fatal(1,"actual decoder packet result");
     packet_expected[f]<=packet_expected[f]+1;packets=packets+1;
    end
   end
   if((m_valid && !m_ready) || (z_valid && !z_ready) || (error_valid && !error_ready))holds=holds+1;
  end
 end
 task reset_epoch;
  begin
   rst=1;cfg_valid=0;s_valid=0;a_valid=0;z_ready=0;m_ready=0;error_ready=0;
   @(posedge clk);@(negedge clk);rst=0;resets=resets+1;repeat(6)@(negedge clk);
   if(m_valid || error_valid || faulted)$fatal(1,"stale epoch");
  end
 endtask
 task configure;
  begin
   cfg_valid=3;timeout=0;
   begin:configs
    forever begin
     @(posedge clk);if(cfg_ready==3)disable configs;timeout=timeout+1;if(timeout>50)$fatal(1,"decoder configure");
    end
   end
   @(negedge clk);cfg_valid=0;if(cfg_ready!=0)$fatal(1,"epoch configuration not locked");
  end
 endtask
 task send_add(input integer f,input [47:0] time_arg,input [63:0] seq_arg,order_arg,input [31:0] quantity_arg,price_arg,input [7:0] tag_arg);
  integer b;
  begin
   for(b=0;b<58;b=b+1)bytes[f][b]=0;
   for(b=0;b<10;b=b+1)bytes[f][b]=cfg_session[f*80+(9-b)*8+:8];
   for(b=0;b<8;b=b+1)bytes[f][10+b]=seq_arg[(7-b)*8+:8];
   bytes[f][18]=0;bytes[f][19]=1;bytes[f][20]=0;bytes[f][21]=36;
   bytes[f][22]="A";bytes[f][23]=8'h12;bytes[f][24]=8'h34;bytes[f][25]=8'h56;bytes[f][26]=8'h78;
   for(b=0;b<6;b=b+1)bytes[f][27+b]=time_arg[(5-b)*8+:8];
   for(b=0;b<8;b=b+1)bytes[f][33+b]=order_arg[(7-b)*8+:8];
   bytes[f][41]="B";
   for(b=0;b<4;b=b+1)bytes[f][42+b]=quantity_arg[(3-b)*8+:8];
   for(b=0;b<8;b=b+1)bytes[f][46+b]=8'h41+b;
   for(b=0;b<4;b=b+1)bytes[f][54+b]=price_arg[(3-b)*8+:8];
   for(b=0;b<58;b=b+1)begin
    s_valid[f]=1;s_data[f*8+:8]=bytes[f][b];s_tag[f*8+:8]=tag_arg;s_last[f]=b==57;s_keep[f]=1;timeout=0;
    begin:byte_accept
     forever begin @(posedge clk);if(s_ready[f])disable byte_accept;timeout=timeout+1;if(timeout>1000)$fatal(1,"decoder input");end
    end
    @(negedge clk);
   end
   s_valid[f]=0;s_last[f]=0;
  end
 endtask
 task admin(input [2:0] op_arg,input [31:0] feed_arg,input [63:0] time_arg,input [3:0] status_arg);
  reg [7:0] saved_tag;
  begin
   saved_tag=admins+8'h30;a_valid=1;a_op=op_arg;a_feed=feed_arg;a_time=time_arg;a_tag=saved_tag;timeout=0;
   begin:admin_accept
    forever begin @(posedge clk);if(a_ready)disable admin_accept;timeout=timeout+1;if(timeout>500)$fatal(1,"admin acceptance");end
   end
   @(negedge clk);a_valid=0;timeout=0;
   while(!z_valid)begin @(negedge clk);timeout=timeout+1;if(timeout>500)$fatal(1,"admin result");end
   if(z_op!==op_arg || z_status!==status_arg || z_tag!==saved_tag)$fatal(1,"admin mismatch op%0d status%0d",z_op,z_status);
   repeat(3)begin @(posedge clk);if(!z_valid || z_status!==status_arg || a_ready)$fatal(1,"held admin");end
   @(negedge clk);z_ready=1;@(posedge clk);@(negedge clk);z_ready=0;admins=admins+1;
  end
 endtask
 task quiet(input integer clocks);
  begin repeat(clocks)begin @(negedge clk);if(m_valid)$fatal(1,"unsafe early release");end end
 endtask
 task consume(input integer feed_arg,input [63:0] time_arg,seq_arg,order_arg,input [31:0] quantity_arg,price_arg,input [7:0] tag_arg,input integer with_future);
  reg [511:0] golden;
  begin
   timeout=0;while(!m_valid)begin @(negedge clk);timeout=timeout+1;if(timeout>600)$fatal(1,"merged output timeout");end
   golden={105'd0,8'h41,16'h1234,16'h5678,order_arg,64'd0,quantity_arg,price_arg,64'h4142434445464748,32'd0,64'd0,1'b0,1'b0,1'b1,1'b1,1'b0,1'b0,1'b1,tag_arg};
   if(m_feed!==feed_arg[0] || m_time!==time_arg || m_sequence!==seq_arg || m_data!==golden)$fatal(1,"decoded merge field/order mismatch feed%0d time%0d seq%0d",m_feed,m_time,m_sequence);
   held_event=event_payload;repeat(3)begin @(posedge clk);if(!m_valid || event_payload!==held_event)$fatal(1,"held event");end
   @(negedge clk);
   if(with_future)begin
    a_valid=1;a_op=2;a_feed=0;a_time=64'hffffffffffffffff;a_tag=8'he0;
    repeat(5)begin @(posedge clk);if(a_ready || !m_valid || event_payload!==held_event)$fatal(1,"admin crossed held event");end
    futures=futures+1;@(negedge clk);
   end
   m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;events=events+1;
   if(with_future)begin
    timeout=0;begin:future_accept
     forever begin @(posedge clk);if(a_ready)disable future_accept;timeout=timeout+1;if(timeout>500)$fatal(1,"future GET acceptance");end
    end
    @(negedge clk);a_valid=0;while(!z_valid)@(negedge clk);
    if(z_status!=0 || z_op!=2 || z_tag!=8'he0 || !z_has_previous || z_previous_time!=time_arg || z_previous_sequence!=seq_arg)$fatal(1,"actual future GET result");
    repeat(3)@(posedge clk);@(negedge clk);z_ready=1;@(posedge clk);@(negedge clk);z_ready=0;admins=admins+1;
   end
  end
 endtask
 initial begin
  @(negedge clk);reset_epoch();configure();
  send_add(0,20,10,1000,7,99,8'ha0);
  timeout=0;while(!dut.occupied[0])begin @(negedge clk);timeout=timeout+1;if(timeout>500)$fatal(1,"first stored head");end
  quiet(40);admin(0,1,20,0);quiet(40);admin(0,1,21,0);
  consume(0,20,10,1000,7,99,8'ha0,1);
  send_add(0,30,11,1001,8,100,8'ha2);send_add(1,25,100,2000,9,98,8'hb0);
  consume(1,25,100,2000,9,98,8'hb0,0);quiet(40);admin(1,1,0,0);consume(0,30,11,1001,8,100,8'ha2,0);
  reset_epoch();configure();send_add(1,40,100,3000,10,101,8'hb1);send_add(0,40,10,3001,11,102,8'ha3);
  consume(0,40,10,3001,11,102,8'ha3,0);quiet(40);
  send_add(0,40,11,3002,12,103,8'ha4);consume(0,40,11,3002,12,103,8'ha4,0);
  admin(0,0,40,0);quiet(40);admin(0,0,41,0);consume(1,40,100,3000,10,101,8'hb1,0);
  send_add(0,39,12,4000,13,104,8'ha9);timeout=0;
  while(!error_valid)begin @(negedge clk);timeout=timeout+1;if(timeout>600)$fatal(1,"source-time isolation");end
  if(!faulted || error_feed!=0 || error_status!=6 || error_tag!=8'ha9 || m_valid)$fatal(1,"wrong source isolation");
  a_valid=1;a_op=2;a_feed=0;a_time=0;a_tag=8'he1;
  repeat(5)begin @(posedge clk);if(a_ready || !error_valid || error_status!=6)$fatal(1,"held error ownership");end
  futures=futures+1;@(negedge clk);error_ready=1;@(posedge clk);@(negedge clk);error_ready=0;
  begin:error_future_accept forever begin @(posedge clk);if(a_ready)disable error_future_accept;end end
  @(negedge clk);a_valid=0;while(!z_valid)@(negedge clk);if(z_status!=11 || z_tag!=8'he1)$fatal(1,"isolated future GET");
  repeat(3)@(posedge clk);@(negedge clk);z_ready=1;@(posedge clk);@(negedge clk);z_ready=0;admins=admins+1;quiet(20);
  reset_epoch();configure();send_add(0,5,10,5000,14,105,8'hc0);admin(1,1,0,0);
  timeout=0;while(!m_valid)begin @(negedge clk);timeout=timeout+1;if(timeout>600)$fatal(1,"reset-held event");end
  repeat(4)@(negedge clk);cancelled=cancelled+1;
  reset_epoch();configure();send_add(1,1,100,6000,15,106,8'hd0);admin(1,0,0,0);
  consume(1,1,100,6000,15,106,8'hd0,0);admin(1,1,0,0);if(!z_end)$fatal(1,"final EOS empty state");
  repeat(10)@(negedge clk);if(m_valid || error_valid || faulted || packets!=9 || events!=7 || admins!=10 || resets!=4 || futures!=2 || cancelled!=1)$fatal(1,"example counts packets%0d events%0d admins%0d",packets,events,admins);
  $display("PASS dual_itch_time_merge packets=%0d events=%0d admins=%0d holds=%0d resets=%0d futures=%0d cancelled=%0d cycles=%0d",packets,events,admins,holds,resets,futures,cancelled,cycles);$finish;
 end
endmodule
