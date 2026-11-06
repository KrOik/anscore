// SPDX-License-Identifier: Apache-2.0
// Two actual strict MoldUDP64/ITCH decoders; reset starts a new whole epoch.
module dual_itch_time_merge #(
 parameter integer TAG_W=8
)(
 input wire clk,rst,
 input wire [1:0] cfg_valid,output wire [1:0] cfg_ready,
 input wire [159:0] cfg_session,input wire [127:0] cfg_next,
 input wire [1:0] s_valid,output wire [1:0] s_ready,input wire [15:0] s_data,
 input wire [1:0] s_keep,s_last,input wire [2*TAG_W-1:0] s_tag,
 output wire [1:0] packet_valid,input wire [1:0] packet_ready,
 output wire [7:0] packet_status,output wire [159:0] packet_session,
 output wire [127:0] packet_sequence,packet_next,output wire [31:0] packet_messages,packet_events,
 output wire [1:0] packet_end,output wire [2*TAG_W-1:0] packet_tag,
 input wire a_valid,output wire a_ready,input wire [2:0] a_op,input wire [31:0] a_feed,
 input wire [63:0] a_time,input wire [TAG_W-1:0] a_tag,
 output wire z_valid,input wire z_ready,output wire [2:0] z_op,output wire [3:0] z_status,
 output wire [31:0] z_feed,z_heads,output wire z_end,z_head,z_closed,z_has_previous,z_has_watermark,
 output wire [63:0] z_previous_time,z_previous_sequence,z_watermark,output wire [TAG_W-1:0] z_tag,
 output wire m_valid,input wire m_ready,output wire m_feed,output wire [63:0] m_time,m_sequence,
 output wire [511:0] m_data,
 output wire error_valid,input wire error_ready,output wire error_feed,output wire [3:0] error_status,
 output wire [TAG_W-1:0] error_tag,output wire faulted
);
 localparam integer PACKED_W=399+TAG_W;
 localparam [3:0] IDLE=0,SEND=1,ADMIN_WAIT=2,EVENT_WAIT=3,POP_WAIT=4,
  ISEND=5,IWAIT=6,ERROR_HOLD=7;
 reg [3:0] state;
 reg [1:0] configured,occupied;
 reg turn,selected_feed,isolated;
 reg [1:0] owner;
 reg [3:0] command_op;
 reg [2:0] admin_op;
 reg [31:0] command_feed;
 reg [63:0] command_time,command_sequence;
 reg [511:0] command_data;
 reg [TAG_W-1:0] command_tag;
 reg error_feed_r;reg [3:0] error_status_r;reg [TAG_W-1:0] error_tag_r;
 wire [1:0] rx_cfg_ready,rx_s_ready,ev_valid,ev_ready;
 wire [1023:0] ev_data;wire [95:0] ev_time;wire [127:0] ev_sequence;
 wire [2*TAG_W-1:0] ev_tag;wire [1:0] rx_busy;
 wire core_ready,core_valid,core_faulted,core_busy;
 wire [3:0] result_op,result_status;
 wire [31:0] result_feed,result_blocked,result_heads;
 wire [63:0] result_time,result_sequence,result_previous_time,result_previous_sequence,result_watermark;
 wire [511:0] result_data;wire [TAG_W-1:0] result_tag;
 wire result_head,result_closed,result_previous,result_watermarked,result_end;
 wire pick=ev_valid[turn] && !occupied[turn]?turn:!turn;
 wire can_event=(ev_valid[0] && !occupied[0]) || (ev_valid[1] && !occupied[1]);
 wire stop=isolated || core_faulted;
 assign a_ready=!rst && state==IDLE;
 assign faulted=!rst && stop;
 assign z_valid=!rst && state==ADMIN_WAIT && core_valid;
 assign z_op=admin_op;assign z_status=result_status;assign z_feed=result_feed;
 assign z_heads=result_heads;assign z_end=result_end;assign z_head=result_head;assign z_closed=result_closed;
 assign z_has_previous=result_previous;assign z_has_watermark=result_watermarked;
 assign z_previous_time=result_previous_time;assign z_previous_sequence=result_previous_sequence;
 assign z_watermark=result_watermark;assign z_tag=result_tag;
 assign m_valid=!rst && state==POP_WAIT && core_valid && result_status==0;
 assign m_feed=result_feed[0];assign m_time=result_time;assign m_sequence=result_sequence;assign m_data=result_data;
 assign error_valid=!rst && state==ERROR_HOLD;
 assign error_feed=error_feed_r;assign error_status=error_status_r;assign error_tag=error_tag_r;
 wire core_result_ready=(state==ADMIN_WAIT && z_ready) || state==EVENT_WAIT ||
  (state==POP_WAIT && (result_status!=0 || m_ready)) || state==IWAIT;
 genvar g;
 generate for(g=0;g<2;g=g+1)begin:decoder
  wire [7:0] kind;wire [15:0] locate,tracking;wire [63:0] order_id,new_order,stock,match_id;
  wire [31:0] quantity,price,attribution;wire sell,printable,price_valid,stock_valid,attribution_valid,match_valid,event_last;
  wire [PACKED_W-1:0] packed_event={kind,locate,tracking,order_id,new_order,quantity,price,stock,attribution,match_id,
   sell,printable,price_valid,stock_valid,attribution_valid,match_valid,event_last,ev_tag[g*TAG_W+:TAG_W]};
  assign ev_data[g*512+:512]={{(512-PACKED_W){1'b0}},packed_event};
  assign cfg_ready[g]=!rst && !configured[g] && state==IDLE && !a_valid && rx_cfg_ready[g];
  assign s_ready[g]=!rst && configured[g] && !stop && rx_s_ready[g];
  assign ev_ready[g]=!rst && state==IDLE && !a_valid && !stop && can_event && pick==g;
  moldudp64_itch_rx #(.MAX_PACKET_BYTES(2048),.TAG_W(TAG_W)) rx(
   .clk(clk),.rst(rst),.cfg_valid(cfg_valid[g] && !configured[g] && state==IDLE && !a_valid),.cfg_ready(rx_cfg_ready[g]),
   .cfg_session(cfg_session[g*80+:80]),.cfg_next(cfg_next[g*64+:64]),
   .s_valid(s_valid[g] && configured[g] && !stop),.s_ready(rx_s_ready[g]),.s_data(s_data[g*8+:8]),
   .s_keep(s_keep[g]),.s_last(s_last[g]),.s_tag(s_tag[g*TAG_W+:TAG_W]),
   .m_valid(ev_valid[g]),.m_ready(ev_ready[g]),.m_type(kind),.m_sequence(ev_sequence[g*64+:64]),
   .m_locate(locate),.m_tracking(tracking),.m_timestamp(ev_time[g*48+:48]),
   .m_order(order_id),.m_new_order(new_order),.m_quantity(quantity),.m_price(price),.m_stock(stock),.m_attribution(attribution),
   .m_match(match_id),.m_sell(sell),.m_printable(printable),.m_price_valid(price_valid),.m_stock_valid(stock_valid),
   .m_attribution_valid(attribution_valid),.m_match_valid(match_valid),.m_last(event_last),.m_tag(ev_tag[g*TAG_W+:TAG_W]),
   .rsp_valid(packet_valid[g]),.rsp_ready(packet_ready[g]),.rsp_status(packet_status[g*4+:4]),
   .rsp_session(packet_session[g*80+:80]),.rsp_sequence(packet_sequence[g*64+:64]),
   .rsp_messages(packet_messages[g*16+:16]),.rsp_events(packet_events[g*16+:16]),.rsp_next(packet_next[g*64+:64]),
   .rsp_end(packet_end[g]),.rsp_tag(packet_tag[g*TAG_W+:TAG_W]),.busy(rx_busy[g]));
 end endgenerate
 watermark_event_merge #(.FEEDS(2),.DATA_W(512),.TAG_W(TAG_W)) merge(
  .clk(clk),.rst(rst),.c_valid(state==SEND || state==ISEND),.c_ready(core_ready),
  .c_op(state==ISEND?4'd6:command_op),.c_feed(command_feed),.c_time(command_time),.c_sequence(command_sequence),
  .c_data(command_data),.c_tag(command_tag),.r_valid(core_valid),.r_ready(core_result_ready),
  .r_op(result_op),.r_status(result_status),.r_feed(result_feed),.r_blocked_feed(result_blocked),
  .r_time(result_time),.r_sequence(result_sequence),.r_data(result_data),.r_tag(result_tag),
  .r_head(result_head),.r_closed(result_closed),.r_has_previous(result_previous),.r_has_watermark(result_watermarked),
  .r_previous_time(result_previous_time),.r_previous_sequence(result_previous_sequence),.r_watermark(result_watermark),
  .r_heads(result_heads),.r_end(result_end),.faulted(core_faulted),.busy(core_busy));
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;configured<=0;occupied<=0;turn<=0;selected_feed<=0;isolated<=0;owner<=0;
   command_op<=0;command_feed<=0;command_time<=0;command_sequence<=0;command_tag<=0;admin_op<=0;
   error_feed_r<=0;error_status_r<=0;error_tag_r<=0;
  end else begin
   if(cfg_valid[0] && cfg_ready[0])configured[0]<=1;
   if(cfg_valid[1] && cfg_ready[1])configured[1]<=1;
   case(state)
    IDLE:begin
     if(a_valid)begin
      admin_op<=a_op;command_feed<=a_feed;command_time<=a_time;command_sequence<=0;command_data<=0;command_tag<=a_tag;
      case(a_op)0:command_op<=1;1:command_op<=2;2:command_op<=4;3:command_op<=6;default:command_op<=15;endcase
      owner<=0;state<=SEND;
     end else if(!stop && can_event)begin
      selected_feed<=pick;command_op<=0;command_feed<={31'd0,pick};command_time<={16'd0,ev_time[pick*48+:48]};
      command_sequence<=ev_sequence[pick*64+:64];command_data<=ev_data[pick*512+:512];command_tag<=ev_tag[pick*TAG_W+:TAG_W];
      turn<=!pick;owner<=1;state<=SEND;
     end else if(!stop && occupied!=0)begin
      command_op<=3;command_feed<=0;command_time<=0;command_sequence<=0;command_data<=0;command_tag<=0;owner<=2;state<=SEND;
     end
    end
    SEND:if(core_ready)begin
     case(owner)0:state<=ADMIN_WAIT;1:state<=EVENT_WAIT;default:state<=POP_WAIT;endcase
    end
    ADMIN_WAIT:if(core_valid && z_ready)state<=IDLE;
    EVENT_WAIT:if(core_valid)begin
     if(result_status==0)begin occupied[selected_feed]<=1;state<=IDLE;end
     else begin
      isolated<=1;error_feed_r<=selected_feed;error_status_r<=result_status;error_tag_r<=result_tag;state<=ISEND;
     end
    end
    POP_WAIT:if(core_valid && core_result_ready)begin
     if(result_status==0)begin occupied[result_feed[0]]<=0;state<=IDLE;end
     else if(result_status==9 || result_status==10)state<=IDLE;
     else begin isolated<=1;error_feed_r<=0;error_status_r<=result_status;error_tag_r<=result_tag;state<=ISEND;end
    end
    ISEND:if(core_ready)state<=IWAIT;
    IWAIT:if(core_valid)state<=ERROR_HOLD;
    ERROR_HOLD:if(error_ready)state<=IDLE;
    default:begin isolated<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
