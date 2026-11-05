// SPDX-License-Identifier: Apache-2.0
// Bounded store/validate/replay MoldUDP64 receiver, ITCH5 order-event subset.
module moldudp64_itch_rx #(
 parameter MAX_PACKET_BYTES=2048, TAG_W=8,
 parameter AW=(MAX_PACKET_BYTES<2)?1:$clog2(MAX_PACKET_BYTES)
)(
 input wire clk,rst,
 input wire cfg_valid,output wire cfg_ready,
 input wire [79:0] cfg_session,input wire [63:0] cfg_next,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,
 input wire s_keep,s_last,input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output reg [7:0] m_type,output reg [63:0] m_sequence,
 output reg [15:0] m_locate,m_tracking,output reg [47:0] m_timestamp,
 output reg [63:0] m_order,m_new_order,output reg [31:0] m_quantity,m_price,
 output reg [63:0] m_stock,output reg [31:0] m_attribution,
 output reg [63:0] m_match,output reg m_sell,m_printable,
 output reg m_price_valid,m_stock_valid,m_attribution_valid,m_match_valid,
 output wire m_last,output wire [TAG_W-1:0] m_tag,
 output wire rsp_valid,input wire rsp_ready,output reg [3:0] rsp_status,
 output reg [79:0] rsp_session,output reg [63:0] rsp_sequence,
 output reg [15:0] rsp_messages,rsp_events,output reg [63:0] rsp_next,
 output reg rsp_end,output wire [TAG_W-1:0] rsp_tag,output wire busy
);
 localparam IDLE=0,CAPTURE=1,CHECK=2,READ_REQ=3,READ_USE=4,BUILD=5,
            EMIT=6,FINISH=7,RESPONSE=8;
 localparam HEADER=0,LEN_HI=1,LEN_LO=2,BODY=3,DONE=4;
 localparam R_HI=0,R_LO=1,R_TYPE=2,R_BODY=3;
 reg [3:0] state;
 reg configured,ended;
 reg [79:0] session;
 reg [63:0] expected_next,candidate_next;
 reg [TAG_W-1:0] tag;
 // Saturates at MAX_PACKET_BYTES+1 while draining an oversized datagram.
 reg [AW:0] byte_count;
 reg [2:0] parse_state;
 reg [79:0] rx_session;
 reg [63:0] rx_sequence;
 reg [15:0] rx_messages,remaining,msg_length,body_index,known_events;
 reg [7:0] length_hi,rx_type;
 reg bad_frame,bad_message,oversize;
 reg [AW:0] n_count;
 reg [2:0] n_parse;
 reg [79:0] n_session;
 reg [63:0] n_sequence;
 reg [15:0] n_messages,n_remaining,n_length,n_body,n_events;
 reg [7:0] n_hi,n_type;
 reg n_frame,n_message,n_over;
 wire [64:0] sequence_sum={1'b0,rx_sequence}+{49'd0,rx_messages};
 (* ram_style="block", syn_ramstyle="block_ram" *)
 reg [7:0] packet_mem[0:MAX_PACKET_BYTES-1];
 reg [AW-1:0] read_addr;
 reg [7:0] read_data;
 reg [1:0] read_phase;
 reg [7:0] replay_hi;
 reg [15:0] replay_length,replay_index,message_index;
 reg [319:0] message_bits;
 function automatic [15:0] itch_length(input [7:0] kind);
  begin case(kind)
   "A":itch_length=36;"F":itch_length=40;"E":itch_length=31;
   "C":itch_length=36;"X":itch_length=23;"D":itch_length=19;
   "U":itch_length=35;default:itch_length=0;
  endcase end
 endfunction
 generate if(MAX_PACKET_BYTES<64 || MAX_PACKET_BYTES>4096 || TAG_W<1 || TAG_W>32 ||
             AW<1 || AW>12 || (32'd1<<AW)<MAX_PACKET_BYTES)begin:invalid
  moldudp64_itch_rx_invalid_parameters__see_README bad_parameters();
 end endgenerate
 assign cfg_ready=!rst && state==IDLE;
 assign s_ready=!rst && ((state==IDLE && !cfg_valid)||state==CAPTURE);
 assign m_valid=!rst && state==EMIT;
 assign m_last=rsp_events==known_events-1'b1;
 assign m_tag=tag;
 assign rsp_valid=!rst && state==RESPONSE;
 assign rsp_tag=tag;
 assign busy=state!=IDLE;
 // A new packet starts from parser defaults; first-byte capture is not a bubble.
 always @* begin
  n_count=byte_count;n_parse=parse_state;n_session=rx_session;n_sequence=rx_sequence;
  n_messages=rx_messages;n_remaining=remaining;n_length=msg_length;n_body=body_index;
  n_events=known_events;n_hi=length_hi;n_type=rx_type;
  n_frame=bad_frame;n_message=bad_message;n_over=oversize;
  if(state==IDLE)begin
   n_count=0;n_parse=HEADER;n_session=0;n_sequence=0;n_messages=0;n_remaining=0;
   n_length=0;n_body=0;n_events=0;n_hi=0;n_type=0;n_frame=0;n_message=0;n_over=0;
  end
  if(n_count<MAX_PACKET_BYTES+1)n_count=n_count+1'b1;
  if((state==IDLE?0:byte_count)>=MAX_PACKET_BYTES)n_over=1;
  if(!s_keep)n_frame=1;
  case(n_parse)
   HEADER:begin
    if((state==IDLE?0:byte_count)<10)n_session={n_session[71:0],s_data};
    else if(byte_count<18)n_sequence={n_sequence[55:0],s_data};
    else if(byte_count==18)n_hi=s_data;
    else begin
     n_messages={n_hi,s_data};n_remaining={n_hi,s_data};
     n_parse=(n_messages==0 || n_messages==16'hffff)?DONE:LEN_HI;
    end
   end
   LEN_HI:begin n_hi=s_data;n_parse=LEN_LO;end
   LEN_LO:begin
    n_length={n_hi,s_data};n_body=0;n_type=0;
    if(n_length==0)begin
     n_remaining=n_remaining-1'b1;n_parse=(n_remaining==0)?DONE:LEN_HI;
    end else n_parse=BODY;
   end
   BODY:begin
    if(n_body==0)begin
     n_type=s_data;
     if(itch_length(s_data)!=0)begin
      n_events=n_events+1'b1;
      if(n_length!=itch_length(s_data))n_message=1;
     end
    end
    if((n_type=="A" || n_type=="F") && n_body==19 && s_data!="B" && s_data!="S")n_message=1;
    if(n_type=="C" && n_body==31 && s_data!="Y" && s_data!="N")n_message=1;
    if(n_body==n_length-1'b1)begin
     n_remaining=n_remaining-1'b1;n_parse=(n_remaining==0)?DONE:LEN_HI;
    end else n_body=n_body+1'b1;
   end
   DONE:n_frame=1;
   default:n_frame=1;
  endcase
 end
 // Disjoint receive-write and replay-read phases; no read/write collision mode.
 always @(posedge clk)begin
  if(!rst && s_valid && s_ready)begin
   if(state==IDLE)packet_mem[0]<=s_data;
   else if(byte_count<MAX_PACKET_BYTES)packet_mem[byte_count[AW-1:0]]<=s_data;
  end
  if(!rst && state==READ_REQ)read_data<=packet_mem[read_addr];
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;configured<=0;ended<=0;session<=0;expected_next<=0;candidate_next<=0;tag<=0;
   byte_count<=0;parse_state<=HEADER;rx_session<=0;rx_sequence<=0;rx_messages<=0;
   remaining<=0;msg_length<=0;body_index<=0;known_events<=0;length_hi<=0;rx_type<=0;
   bad_frame<=0;bad_message<=0;oversize<=0;read_addr<=0;read_phase<=R_HI;replay_hi<=0;
   replay_length<=0;replay_index<=0;message_index<=0;message_bits<=0;
   m_type<=0;m_sequence<=0;m_locate<=0;m_tracking<=0;m_timestamp<=0;
   m_order<=0;m_new_order<=0;m_quantity<=0;m_price<=0;m_stock<=0;m_attribution<=0;
   m_match<=0;m_sell<=0;m_printable<=0;m_price_valid<=0;m_stock_valid<=0;
   m_attribution_valid<=0;m_match_valid<=0;
   rsp_status<=0;rsp_session<=0;rsp_sequence<=0;rsp_messages<=0;rsp_events<=0;rsp_next<=0;rsp_end<=0;
  end else begin
   if(s_valid && s_ready)begin
    if(state==IDLE)begin tag<=s_tag;rsp_events<=0;end
    byte_count<=n_count;parse_state<=n_parse;rx_session<=n_session;rx_sequence<=n_sequence;
    rx_messages<=n_messages;remaining<=n_remaining;msg_length<=n_length;body_index<=n_body;
    known_events<=n_events;length_hi<=n_hi;rx_type<=n_type;
    bad_frame<=n_frame;bad_message<=n_message;oversize<=n_over;
    state<=s_last?CHECK:CAPTURE;
   end
   case(state)
    IDLE:if(cfg_valid)begin configured<=1;session<=cfg_session;expected_next<=cfg_next;ended<=0;end
    CHECK:begin
     rsp_status<=0;rsp_session<=byte_count<20?80'd0:rx_session;
     rsp_sequence<=byte_count<20?64'd0:rx_sequence;rsp_messages<=byte_count<20?16'd0:rx_messages;
     rsp_next<=expected_next;rsp_end<=ended;
     if(oversize)begin rsp_status<=2;state<=RESPONSE;end
     else if(bad_frame || parse_state!=DONE)begin rsp_status<=3;state<=RESPONSE;end
     else if(bad_message)begin rsp_status<=4;state<=RESPONSE;end
     else if(!configured)begin rsp_status<=1;state<=RESPONSE;end
     else if(rx_session!=session)begin rsp_status<=5;state<=RESPONSE;end
     else if(rx_sequence<expected_next)begin rsp_status<=6;state<=RESPONSE;end
     else if(rx_sequence>expected_next)begin rsp_status<=7;state<=RESPONSE;end
     else if(ended && rx_messages!=0 && rx_messages!=16'hffff)begin rsp_status<=8;state<=RESPONSE;end
     else if(rx_messages!=0 && rx_messages!=16'hffff && sequence_sum[64])begin rsp_status<=9;state<=RESPONSE;end
     else begin
      candidate_next<=(rx_messages==0 || rx_messages==16'hffff)?expected_next:sequence_sum[63:0];
      read_addr<=20;message_index<=0;read_phase<=R_HI;
      state<=(rx_messages==0 || rx_messages==16'hffff)?FINISH:READ_REQ;
     end
    end
    READ_REQ:state<=READ_USE;
    READ_USE:begin
     read_addr<=read_addr+1'b1;state<=READ_REQ;
     case(read_phase)
      R_HI:begin replay_hi<=read_data;read_phase<=R_LO;end
      R_LO:begin
       replay_length<={replay_hi,read_data};replay_index<=0;message_bits<=0;read_phase<=R_TYPE;
       if({replay_hi,read_data}==0)begin
        if(message_index==rx_messages-1'b1)state<=FINISH;
        else begin message_index<=message_index+1'b1;read_phase<=R_HI;end
       end
      end
      R_TYPE:begin
       if(itch_length(read_data)==0)begin
        // Current address owns byte0; add complete body length to skip it.
        read_addr<=read_addr+replay_length;
        if(message_index==rx_messages-1'b1)state<=FINISH;
        else begin message_index<=message_index+1'b1;read_phase<=R_HI;end
       end else begin
        message_bits[319:312]<=read_data;replay_index<=1;read_phase<=R_BODY;
       end
      end
      R_BODY:begin
       message_bits[319-replay_index*8-:8]<=read_data;
       if(replay_index==replay_length-1'b1)state<=BUILD;
       else replay_index<=replay_index+1'b1;
      end
     endcase
    end
    BUILD:begin
     m_type<=message_bits[319:312];m_sequence<=rx_sequence+message_index;
     m_locate<=message_bits[311:296];m_tracking<=message_bits[295:280];m_timestamp<=message_bits[279:232];
     m_order<=message_bits[231:168];m_new_order<=0;m_quantity<=0;m_price<=0;m_stock<=0;
     m_attribution<=0;m_match<=0;m_sell<=0;m_printable<=0;
     m_price_valid<=0;m_stock_valid<=0;m_attribution_valid<=0;m_match_valid<=0;
     case(message_bits[319:312])
      "A","F":begin
       m_sell<=message_bits[167:160]=="S";m_quantity<=message_bits[159:128];
       m_stock<=message_bits[127:64];m_price<=message_bits[63:32];m_price_valid<=1;m_stock_valid<=1;
       if(message_bits[319:312]=="F")begin m_attribution<=message_bits[31:0];m_attribution_valid<=1;end
      end
      "E","C":begin
       m_quantity<=message_bits[167:136];m_match<=message_bits[135:72];m_match_valid<=1;
       m_printable<=message_bits[319:312]=="E" || message_bits[71:64]=="Y";
       if(message_bits[319:312]=="C")begin m_price<=message_bits[63:32];m_price_valid<=1;end
      end
      "X":m_quantity<=message_bits[167:136];
      "U":begin m_new_order<=message_bits[167:104];m_quantity<=message_bits[103:72];
                m_price<=message_bits[71:40];m_price_valid<=1;end
      default:begin end
     endcase
     state<=EMIT;
    end
    EMIT:if(m_ready)begin
     rsp_events<=rsp_events+1'b1;
     if(message_index==rx_messages-1'b1)state<=FINISH;
     else begin message_index<=message_index+1'b1;read_phase<=R_HI;state<=READ_REQ;end
    end
    FINISH:begin
     expected_next<=candidate_next;ended<=ended || rx_messages==16'hffff;
     rsp_next<=candidate_next;rsp_end<=ended || rx_messages==16'hffff;state<=RESPONSE;
    end
    RESPONSE:if(rsp_ready)state<=IDLE;
    default:begin end
   endcase
  end
 end
endmodule
