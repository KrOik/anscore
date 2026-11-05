`timescale 1ns/1ps
module tb_moldudp64_itch_rx;
 parameter MAX_PACKET_BYTES=257,TAG_W=9;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cfg_valid=0,s_valid=0,s_keep=1,s_last=0,m_ready=0,rsp_ready=0;
 reg [79:0] cfg_session=0;reg [63:0] cfg_next=0;
 reg [7:0] s_data=0;reg [TAG_W-1:0] s_tag=0;
 wire cfg_ready,s_ready,m_valid,m_sell,m_printable,m_price_valid,m_stock_valid,m_attribution_valid,m_match_valid,m_last;
 wire [7:0] m_type;wire [63:0] m_sequence,m_order,m_new_order,m_stock,m_match;
 wire [15:0] m_locate,m_tracking;wire [47:0] m_timestamp;wire [31:0] m_quantity,m_price,m_attribution;
 wire [TAG_W-1:0] m_tag,rsp_tag;wire rsp_valid,rsp_end,busy;
 wire [3:0] rsp_status;wire [79:0] rsp_session;wire [63:0] rsp_sequence,rsp_next;
 wire [15:0] rsp_messages,rsp_events;
 moldudp64_itch_rx #(.MAX_PACKET_BYTES(MAX_PACKET_BYTES),.TAG_W(TAG_W)) dut(.*);
 integer fd,rv,op,n,k,j,phase;
 integer bytes[0:MAX_PACKET_BYTES+20],keeps[0:MAX_PACKET_BYTES+20];
 reg [511+TAG_W-1:0] expected_payload[0:MAX_PACKET_BYTES];
 reg [7:0] etype;reg [63:0] eseq,eorder,enew,estock,ematch;
 reg [15:0] elocate,etracking;reg [47:0] etime;reg [31:0] eqty,eprice,eattr;
 integer esell,eprint,epv,esv,eav,emv,elast;
 reg [TAG_W-1:0] etag,packet_tag;
 integer status_exp,ne,received=0,expected=0,accepted=0;
 reg [79:0] session_exp;reg [63:0] sequence_exp,next_exp;reg [15:0] messages_exp;
 integer end_exp;
 integer cycles=0,packets=0,events=0,configs=0,stalls=0,done_holds=0,resets=0;
 reg collecting=0,force_stall=0,holding=0,input_held=0;
 reg [510+TAG_W:0] held;
 wire [510+TAG_W:0] payload={m_type,m_sequence,m_locate,m_tracking,m_timestamp,m_order,m_new_order,m_quantity,m_price,m_stock,m_attribution,m_match,m_sell,m_printable,m_price_valid,m_stock_valid,m_attribution_valid,m_match_valid,m_last,m_tag};
 reg [10+TAG_W:0] held_input;
 wire [10+TAG_W:0] input_payload={s_data,s_keep,s_last,s_tag};
 reg [244+TAG_W:0] held_rsp;
 string vectors;
 always @(negedge clk)begin cycles=cycles+1;if(cycles>1000000)$fatal(1,"bounded watchdog");m_ready=collecting&&!force_stall&&(cycles%11>=4);end
 always @(posedge clk)if(!rst)begin
  if(input_held && (!s_valid || input_payload!==held_input))$fatal(1,"source changed while blocked");
  input_held=s_valid&&!s_ready;held_input=input_payload;
  if(s_valid&&s_ready)accepted=accepted+1;
  if(holding && (!m_valid || payload!==held))$fatal(1,"event changed while blocked");
  holding=m_valid&&!m_ready;held=payload;if(holding)stalls=stalls+1;
  if(m_valid&&m_ready)begin
   if(!collecting || received>=expected || payload!==expected_payload[received])
    $fatal(1,"event mismatch at packet%0d event%0d type%h seq%h got%h exp%h",packets,received,m_type,m_sequence,payload,expected_payload[received]);
   received=received+1;events=events+1;
  end
  if(rsp_valid&&collecting&&received!=expected)$fatal(1,"completion before events retired");
  if(busy&&cfg_ready)$fatal(1,"busy configure");
 end
 task reset_core;
  begin
   @(negedge clk);rst=1;cfg_valid=0;s_valid=0;rsp_ready=0;collecting=0;holding=0;input_held=0;force_stall=0;
   repeat(2)@(posedge clk);@(negedge clk);rst=0;resets=resets+1;
   @(posedge clk);if(busy||m_valid||rsp_valid)$fatal(1,"reset cancellation");
  end
 endtask
 task send_bytes(input integer length,input integer limit);
  integer i;
  begin
   for(i=0;i<limit;i=i+1)begin
    @(negedge clk);s_data=bytes[i];s_keep=keeps[i];s_last=i==length-1;s_tag=packet_tag+i;s_valid=1;
    do @(posedge clk);while(!s_ready);
    if(i%5==2)begin @(negedge clk);s_valid=0;repeat(i%3)@(negedge clk);end
   end
   @(negedge clk);s_valid=0;
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"vectors required");
  fd=$fopen(vectors,"r");if(!fd)$fatal(1,"file missing");reset_core();
  while(!$feof(fd))begin
   rv=$fscanf(fd,"%d",op);
   if(rv==1)case(op)
    0:begin
     rv=$fscanf(fd,"%d %d",session_exp,next_exp);if(rv!=2)$fatal(1,"config record");
     @(negedge clk);cfg_session=session_exp;cfg_next=next_exp;cfg_valid=1;
     do @(posedge clk);while(!cfg_ready);
     @(negedge clk);cfg_valid=0;configs=configs+1;
    end
    1:begin
     rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",n,status_exp,session_exp,sequence_exp,messages_exp,ne,next_exp,end_exp,packet_tag);
     if(rv!=9)$fatal(1,"packet record");
     for(k=0;k<n;k=k+1)begin rv=$fscanf(fd,"%d %d",bytes[k],keeps[k]);if(rv!=2)$fatal(1,"byte record");end
     for(k=0;k<ne;k=k+1)begin
      rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",etype,eseq,elocate,etracking,etime,eorder,enew,eqty,eprice,estock,eattr,ematch,esell,eprint,epv,esv,eav,emv,elast,etag);
      if(rv!=20)$fatal(1,"event record");
      expected_payload[k]={etype,eseq,elocate,etracking,etime,eorder,enew,eqty,eprice,estock,eattr,ematch,esell[0],eprint[0],epv[0],esv[0],eav[0],emv[0],elast[0],etag};
     end
     collecting=1;received=0;expected=ne;accepted=0;send_bytes(n,n);
     do @(posedge clk);while(!rsp_valid);
     if(accepted!=n)$fatal(1,"input count");
     held_rsp={rsp_status,rsp_session,rsp_sequence,rsp_messages,rsp_events,rsp_next,rsp_end,rsp_tag};
     repeat(5)begin
      if(!rsp_valid||held_rsp!=={rsp_status,rsp_session,rsp_sequence,rsp_messages,rsp_events,rsp_next,rsp_end,rsp_tag}||rsp_status!==status_exp[3:0]||rsp_session!==session_exp||rsp_sequence!==sequence_exp||rsp_messages!==messages_exp||rsp_events!==ne[15:0]||rsp_next!==next_exp||rsp_end!==end_exp[0]||rsp_tag!==packet_tag)
       $fatal(1,"completion packet%0d got status%0d next%h count%0d events%0d end%0d expected status%0d next%h count%0d events%0d end%0d",packets,rsp_status,rsp_next,rsp_messages,rsp_events,rsp_end,status_exp,next_exp,messages_exp,ne,end_exp);
      done_holds=done_holds+1;@(posedge clk);
     end
     @(negedge clk);rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;collecting=0;packets=packets+1;
     if(busy)$fatal(1,"completion release");
    end
    3:begin
     rv=$fscanf(fd,"%d %d",phase,n);if(rv!=2)$fatal(1,"reset record");
     for(k=0;k<n;k=k+1)begin rv=$fscanf(fd,"%d %d",bytes[k],keeps[k]);if(rv!=2)$fatal(1,"reset byte record");end
     packet_tag=0;force_stall=1;
     if(phase==0)send_bytes(n,7);
     else begin
      send_bytes(n,n);
      if(phase==1)begin do @(posedge clk);while(dut.state!=3);end
      else if(phase==2)begin do @(posedge clk);while(!m_valid);repeat(4)@(posedge clk);end
      else begin do @(posedge clk);while(!rsp_valid);repeat(4)@(posedge clk);end
     end
     reset_core();
    end
    default:$fatal(1,"bad operation");
   endcase
  end
  repeat(8)@(posedge clk);if(busy||m_valid||rsp_valid)$fatal(1,"trailing state");
  $display("PASS moldudp64_itch_rx MAX=%0d T=%0d packets=%0d events=%0d configs=%0d stalls=%0d done_holds=%0d resets=%0d cycles=%0d",MAX_PACKET_BYTES,TAG_W,packets,events,configs,stalls,done_holds,resets,cycles);$finish;
 end
endmodule
