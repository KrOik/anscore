// SPDX-License-Identifier: Apache-2.0
// Single-instrument live ITCH order state. Two unchanged 64/64 hash instances.
module itch_order_state #(
 parameter ORDERS=32,TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,
 input wire [15:0] c_locate,input wire [63:0] c_stock,c_order,
 input wire [TAG_W-1:0] c_tag,
 input wire e_valid,output wire e_ready,input wire [7:0] e_type,
 input wire [15:0] e_locate,input wire [63:0] e_order,e_new_order,
 input wire e_sell,input wire [31:0] e_quantity,e_price,
 input wire [63:0] e_stock,e_sequence,input wire [TAG_W-1:0] e_tag,
 output wire r_valid,input wire r_ready,output reg r_admin,
 output reg [7:0] r_op,output reg [3:0] r_status,
 output reg [63:0] r_request_order,r_sequence,output reg [TAG_W-1:0] r_tag,
 output reg r_old_valid,r_old_sell,output reg [63:0] r_old_order,
 output reg [31:0] r_old_price,r_old_quantity,
 output reg r_new_valid,r_new_sell,output reg [63:0] r_new_order,
 output reg [31:0] r_new_price,r_new_quantity,
 output reg r_remove_valid,output reg [31:0] r_remove_quantity,
 output reg r_add_valid,
 output wire [31:0] r_count,r_bid_orders,r_ask_orders,
 output reg configured,faulted,output wire busy
);
 localparam CW=(ORDERS<2)?1:$clog2(ORDERS+1);
 localparam IDLE=0,SEND=1,WAIT_REPLY=2,EVALUATE=3,RESPONSE=4;
 localparam P_CLEAR=0,P_OLD=1,P_NEW=2,P_WRITE=3,P_ERASE=4,P_REPLACE_ERASE=5,P_REPLACE_PUT=6;
 reg [2:0] state,phase;
 reg [15:0] selected_locate,pending_locate;
 reg [63:0] selected_stock,pending_stock;
 reg [7:0] kind;
 reg [1:0] admin_op;
 reg [63:0] order_id,new_id;
 reg [31:0] quantity,price;
 reg sell;
 reg old_sell;
 reg [31:0] old_price,old_quantity;
 reg [1:0] request_mask,sent_mask,seen_mask,hash_op;
 reg [63:0] hash_key,hash_value;
 wire [1:0] h_ready,h_valid,h_found,h_inserted;
 wire [3:0] h_status;
 wire [127:0] h_value;
 wire [2*CW-1:0] h_count;
 wire [2*TAG_W-1:0] h_tag;
 reg [1:0] got_found,got_inserted;
 reg [3:0] got_status;
 reg [127:0] got_value;
 reg [31:0] bid_count,ask_count;
 wire [1:0] send_fire=request_mask & ~sent_mask & h_ready;
 wire [1:0] response_fire=request_mask & ~seen_mask & h_valid;
 wire found_side=got_found[1];
 wire [63:0] found_value=found_side?got_value[127:64]:got_value[63:0];
 wire get_consistent=((got_status[1:0]==0 && got_found[0]) || (got_status[1:0]==1 && !got_found[0])) &&
                     ((got_status[3:2]==0 && got_found[1]) || (got_status[3:2]==1 && !got_found[1])) &&
                     got_found!=2'b11;
 wire [1:0] selected_status=old_sell?got_status[3:2]:got_status[1:0];
 wire selected_found=got_found[old_sell];
 wire selected_inserted=got_inserted[old_sell];
 wire [63:0] selected_value=old_sell?got_value[127:64]:got_value[63:0];
 wire is_add=kind=="A" || kind=="F";
 wire is_cut=kind=="E" || kind=="C" || kind=="X";
 assign c_ready=!rst && state==IDLE && (&h_ready);
 assign e_ready=c_ready && !c_valid;
 assign r_valid=!rst && state==RESPONSE;
 assign r_count=bid_count+ask_count;assign r_bid_orders=bid_count;assign r_ask_orders=ask_count;
 assign busy=state!=IDLE || !(&h_ready);
 generate if(ORDERS<1 || ORDERS>64 || (ORDERS&(ORDERS-1))!=0 || TAG_W<1 || TAG_W>32)begin:invalid
  itch_order_state_invalid_parameters__see_README bad_parameters();
 end endgenerate
 genvar side;
 generate for(side=0;side<2;side=side+1)begin: sides
  ram_hash_table #(.SLOTS(ORDERS),.KEY_W(64),.VALUE_W(64),.TAG_W(TAG_W)) orders(
   .clk(clk),.rst(rst),.c_valid(!rst && state==SEND && request_mask[side] && !sent_mask[side]),
   .c_ready(h_ready[side]),.c_op(hash_op),.c_key(hash_key),.c_value(hash_value),.c_tag({TAG_W{1'b0}}),
   .r_valid(h_valid[side]),.r_ready(!rst && state==WAIT_REPLY && request_mask[side] && !seen_mask[side]),
   .r_status(h_status[side*2+:2]),.r_found(h_found[side]),.r_inserted(h_inserted[side]),
   .r_old_value(h_value[side*64+:64]),.r_count(h_count[side*CW+:CW]),.r_tag(h_tag[side*TAG_W+:TAG_W]));
 end endgenerate
 task start_batch(input [2:0] next_phase,input [1:0] mask,op,input [63:0] key,value);
  begin
   phase<=next_phase;request_mask<=mask;sent_mask<=0;seen_mask<=0;
   hash_op<=op;hash_key<=key;hash_value<=value;state<=SEND;
  end
 endtask
 task clear_fields;
  begin
   r_status<=0;r_old_valid<=0;r_old_sell<=0;r_old_order<=0;r_old_price<=0;r_old_quantity<=0;
   r_new_valid<=0;r_new_sell<=0;r_new_order<=0;r_new_price<=0;r_new_quantity<=0;
   r_remove_valid<=0;r_remove_quantity<=0;r_add_valid<=0;
  end
 endtask
 task error_reply(input [3:0] status,input poison);
  begin r_status<=status;if(poison)faulted<=1;state<=RESPONSE;end
 endtask
 task publish_event;
  begin
   if(is_add)begin
    r_new_valid<=1;r_new_order<=order_id;r_new_sell<=sell;r_new_price<=price;r_new_quantity<=quantity;r_add_valid<=1;
   end else begin
    r_old_valid<=1;r_old_order<=order_id;r_old_sell<=old_sell;r_old_price<=old_price;r_old_quantity<=old_quantity;
    r_remove_valid<=1;r_remove_quantity<=is_cut?quantity:old_quantity;
    if(kind=="U")begin
     r_new_valid<=1;r_new_order<=new_id;r_new_sell<=old_sell;r_new_price<=price;r_new_quantity<=quantity;r_add_valid<=1;
    end else if(is_cut && quantity<old_quantity)begin
     r_new_valid<=1;r_new_order<=order_id;r_new_sell<=old_sell;r_new_price<=old_price;r_new_quantity<=old_quantity-quantity;
    end
   end
   state<=RESPONSE;
  end
 endtask
 integer i;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;phase<=0;configured<=0;faulted<=0;selected_locate<=0;selected_stock<=0;
   pending_locate<=0;pending_stock<=0;kind<=0;admin_op<=0;order_id<=0;new_id<=0;
   quantity<=0;price<=0;sell<=0;old_sell<=0;old_price<=0;old_quantity<=0;
   request_mask<=0;sent_mask<=0;seen_mask<=0;hash_op<=0;hash_key<=0;hash_value<=0;
   got_found<=0;got_inserted<=0;got_status<=0;got_value<=0;bid_count<=0;ask_count<=0;
   r_admin<=0;r_op<=0;r_request_order<=0;r_sequence<=0;r_tag<=0;clear_fields();
  end else case(state)
   IDLE:begin
    if(c_valid && c_ready)begin
     clear_fields();r_admin<=1;r_op<={6'd0,c_op};r_request_order<=c_order;r_sequence<=0;r_tag<=c_tag;
     admin_op<=c_op;order_id<=c_order;
     if(c_op==0 || c_op==1)begin
      pending_locate<=c_locate;pending_stock<=c_stock;start_batch(P_CLEAR,2'b11,2'd3,0,0);
     end else if(c_op==3)begin faulted<=1;state<=RESPONSE;end
     else if(!configured)error_reply(2,0);
     else if(faulted)error_reply(3,0);
     else start_batch(P_OLD,2'b11,2'd0,c_order,0);
    end else if(e_valid && e_ready)begin
     clear_fields();r_admin<=0;r_op<=e_type;r_request_order<=e_order;r_sequence<=e_sequence;r_tag<=e_tag;
     kind<=e_type;order_id<=e_order;new_id<=e_new_order;quantity<=e_quantity;price<=e_price;sell<=e_sell;
     if(!configured)error_reply(2,0);
     else if(e_locate!=selected_locate)error_reply(1,0);
     else if(faulted)error_reply(3,0);
     else if((e_type!="A" && e_type!="F" && e_type!="E" && e_type!="C" && e_type!="X" && e_type!="D" && e_type!="U") ||
             (e_type!="D" && e_quantity==0) ||
             ((e_type=="A" || e_type=="F") && e_stock!=selected_stock) ||
             (e_type=="U" && e_new_order==e_order))error_reply(4,1);
     else start_batch(P_OLD,2'b11,2'd0,e_order,0);
    end
   end
   SEND:begin
    sent_mask<=sent_mask|send_fire;
    if((sent_mask|send_fire)==request_mask)state<=WAIT_REPLY;
   end
   WAIT_REPLY:begin
    for(i=0;i<2;i=i+1)if(response_fire[i])begin
     got_status[i*2+:2]<=h_status[i*2+:2];got_found[i]<=h_found[i];got_inserted[i]<=h_inserted[i];
     got_value[i*64+:64]<=h_value[i*64+:64];
     if(i==0)bid_count<=h_count[i*CW+:CW];else ask_count<=h_count[i*CW+:CW];
    end
    seen_mask<=seen_mask|response_fire;
    if((seen_mask|response_fire)==request_mask)state<=EVALUATE;
   end
   EVALUATE:case(phase)
    P_CLEAR:begin
     if(got_status!=0 || got_found!=0 || got_inserted!=0 || bid_count!=0 || ask_count!=0)error_reply(9,1);
     else begin
      if(admin_op==0)begin configured<=1;selected_locate<=pending_locate;selected_stock<=pending_stock;end
      faulted<=0;state<=RESPONSE;
     end
    end
    P_OLD:begin
     if(!get_consistent)error_reply(9,1);
     else if(r_admin)begin
      if(got_found==0)error_reply(6,0);
      else begin
       r_old_valid<=1;r_new_valid<=1;r_old_order<=order_id;r_new_order<=order_id;
       r_old_sell<=found_side;r_new_sell<=found_side;
       r_old_price<=found_value[63:32];r_new_price<=found_value[63:32];
       r_old_quantity<=found_value[31:0];r_new_quantity<=found_value[31:0];state<=RESPONSE;
      end
     end else if(is_add)begin
      if(got_found!=0)error_reply(5,1);
      else if(bid_count+ask_count>=ORDERS)error_reply(7,1);
      else begin old_sell<=sell;start_batch(P_WRITE,sell?2'b10:2'b01,2'd1,order_id,{price,quantity});end
     end else if(got_found==0)error_reply(6,1);
     else begin
      old_sell<=found_side;old_price<=found_value[63:32];old_quantity<=found_value[31:0];
      if(is_cut && quantity>found_value[31:0])error_reply(8,1);
      else if(kind=="U")start_batch(P_NEW,2'b11,2'd0,new_id,0);
      else if(kind=="D" || quantity==found_value[31:0])start_batch(P_ERASE,found_side?2'b10:2'b01,2'd2,order_id,0);
      else start_batch(P_WRITE,found_side?2'b10:2'b01,2'd1,order_id,{found_value[63:32],(found_value[31:0]-quantity)});
     end
    end
    P_NEW:begin
     if(!get_consistent)error_reply(9,1);
     else if(got_found!=0)error_reply(5,1);
     else start_batch(P_REPLACE_ERASE,old_sell?2'b10:2'b01,2'd2,order_id,0);
    end
    P_WRITE:begin
     if(selected_status!=0 || (is_add?(selected_found || !selected_inserted || selected_value!=0):
          (!selected_found || selected_inserted || selected_value!={old_price,old_quantity})))error_reply(9,1);
     else publish_event();
    end
    P_ERASE,P_REPLACE_ERASE:begin
     if(selected_status!=0 || !selected_found || selected_inserted || selected_value!={old_price,old_quantity})error_reply(9,1);
     else if(phase==P_REPLACE_ERASE)start_batch(P_REPLACE_PUT,old_sell?2'b10:2'b01,2'd1,new_id,{price,quantity});
     else publish_event();
    end
    P_REPLACE_PUT:begin
     if(selected_status!=0 || selected_found || !selected_inserted || selected_value!=0)error_reply(9,1);
     else publish_event();
    end
    default:error_reply(9,1);
   endcase
   RESPONSE:if(r_ready)state<=IDLE;
   default:error_reply(9,1);
  endcase
 end
endmodule
