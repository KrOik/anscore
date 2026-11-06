// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Packed fixed-IHL header service. Payload ownership remains with the caller.
module ipv4_lpm_forward #(
 parameter integer ROUTES=32,TAG_W=8,
 localparam integer CW=(ROUTES>1?$clog2(ROUTES+1):1)
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,
 input wire [31:0] c_prefix,c_length,c_next_hop,input wire [7:0] c_port,
 input wire [TAG_W-1:0] c_tag,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_status,
 output wire c_found,c_inserted,output wire [31:0] c_old_prefix,c_old_next_hop,
 output wire [5:0] c_old_length,output wire [7:0] c_old_port,
 output wire [CW-1:0] c_count,output wire [TAG_W-1:0] c_rsp_tag,
 input wire p_valid,output wire p_ready,input wire [159:0] p_header,
 input wire [15:0] p_bytes,input wire [TAG_W-1:0] p_tag,
 output wire m_valid,input wire m_ready,output reg [2:0] m_error,
 output wire [159:0] m_header,output reg [31:0] m_next_hop,m_prefix,
 output reg [7:0] m_port,output reg [5:0] m_prefix_length,
 output reg [CW-1:0] m_count,output reg [TAG_W-1:0] m_tag
);
 localparam [3:0] IDLE=0,CFG_SEND=1,CFG_WAIT=2,PRECHECK=3,
  SUM_SEND=4,SUM_WAIT=5,LOOK_SEND=6,LOOK_WAIT=7,OUTPUT=8;
 reg [3:0] state;
 reg [1:0] op_q;
 reg [31:0] key_q,length_q;
 reg [39:0] value_q;
 reg [TAG_W-1:0] cfg_tag_q;
 reg [159:0] header_q,work_header;
 reg [15:0] bytes_q;
 reg [2:0] pair_index;
 reg generate_sum;
 wire table_c_ready,table_r_valid;
 wire [1:0] table_status;
 wire table_found,table_inserted;
 wire [31:0] table_prefix;
 wire [5:0] table_length;
 wire [39:0] table_value;
 wire [CW-1:0] table_count;
 wire [TAG_W-1:0] table_tag;
 wire table_send=state==CFG_SEND||state==LOOK_SEND;
 wire table_take=(state==CFG_WAIT&&c_rsp_ready)||state==LOOK_WAIT;
 ram_prefix_table #(.SLOTS(ROUTES),.KEY_W(32),.VALUE_W(40),.TAG_W(TAG_W)) routes(
  .clk(clk),.rst(rst),.c_valid(!rst&&table_send),.c_ready(table_c_ready),
  .c_op(state==CFG_SEND?op_q:2'd0),.c_key(state==CFG_SEND?key_q:header_q[31:0]),
  .c_length(length_q),.c_value(value_q),.c_tag(state==CFG_SEND?cfg_tag_q:m_tag),
  .r_valid(table_r_valid),.r_ready(!rst&&table_take),.r_status(table_status),
  .r_found(table_found),.r_inserted(table_inserted),.r_prefix(table_prefix),
  .r_length(table_length),.r_value(table_value),.r_count(table_count),.r_tag(table_tag));
 wire sum_in_ready,sum_out_valid,sum_fault;
 wire [31:0] sum_result,sum_aux;
 wire [159:0] sum_header=generate_sum?work_header:header_q;
 wire [31:0] sum_word=sum_header[159-32*pair_index -:32];
 // Fold after each two-word addition: <=65535+2*65535=196605<2^18.
 wire [31:0] sum_control={pair_index==0,1'b1,(!generate_sum&&pair_index==4),29'd0};
 acc_ipv4_hdr_csum checksum(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.in_valid(!rst&&state==SUM_SEND),
  .in_ready(sum_in_ready),.a(sum_word),.b(32'd0),.c(sum_control),
  .out_valid(sum_out_valid),.out_ready(!rst&&state==SUM_WAIT),
  .result(sum_result),.aux(sum_aux),.fault(sum_fault));
 assign c_ready=!rst&&state==IDLE;
 assign p_ready=!rst&&state==IDLE&&!c_valid;
 assign c_rsp_valid=!rst&&state==CFG_WAIT&&table_r_valid;
 assign c_status=table_status;
 assign c_found=table_found;
 assign c_inserted=table_inserted;
 assign c_old_prefix=table_prefix;
 assign c_old_length=table_length;
 assign c_old_next_hop=table_value[31:0];
 assign c_old_port=table_value[39:32];
 assign c_count=table_count;
 assign c_rsp_tag=table_tag;
 assign m_valid=!rst&&state==OUTPUT;
 assign m_header=m_error==0?work_header:header_q;
 wire format_ok=header_q[159:152]==8'h45&&bytes_q>=20&&
  header_q[143:128]>=20&&header_q[143:128]<=bytes_q&&!header_q[111]&&
  !(header_q[110]&&(|header_q[109:96]));
 task automatic fail_packet(input [2:0] code);
  begin
   m_error<=code;m_next_hop<=0;m_port<=0;m_prefix<=0;m_prefix_length<=0;state<=OUTPUT;
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;op_q<=0;key_q<=0;length_q<=0;value_q<=0;cfg_tag_q<=0;
   header_q<=0;work_header<=0;bytes_q<=0;pair_index<=0;generate_sum<=0;
   m_error<=0;m_next_hop<=0;m_prefix<=0;m_port<=0;m_prefix_length<=0;m_count<=0;m_tag<=0;
  end else case(state)
   IDLE:begin
    if(c_valid)begin
     op_q<=c_op;key_q<=c_prefix;length_q<=c_length;value_q<={c_port,c_next_hop};
     cfg_tag_q<=c_tag;state<=CFG_SEND;
    end else if(p_valid)begin
     header_q<=p_header;bytes_q<=p_bytes;m_tag<=p_tag;m_count<=table_count;
     m_error<=0;m_next_hop<=0;m_prefix<=0;m_port<=0;m_prefix_length<=0;
     state<=PRECHECK;
    end
   end
   CFG_SEND:if(table_c_ready)state<=CFG_WAIT;
   CFG_WAIT:if(table_r_valid&&c_rsp_ready)state<=IDLE;
   PRECHECK:begin
    if(!format_ok)fail_packet(1);
    else begin generate_sum<=0;pair_index<=0;state<=SUM_SEND;end
   end
   SUM_SEND:if(sum_in_ready)state<=SUM_WAIT;
   SUM_WAIT:if(sum_out_valid)begin
    if(pair_index<4)begin
     if(sum_fault)fail_packet(5);
     else begin pair_index<=pair_index+1'b1;state<=SUM_SEND;end
    end else if(!generate_sum)begin
     if(sum_fault||sum_result[15:0]!=16'hffff)fail_packet(2);
     else if(header_q[95:88]<=1)fail_packet(3);
     else state<=LOOK_SEND;
    end else begin
     if(sum_fault)fail_packet(5);
     else begin work_header[79:64]<=sum_result[15:0];state<=OUTPUT;end
    end
   end
   LOOK_SEND:if(table_c_ready)state<=LOOK_WAIT;
   LOOK_WAIT:if(table_r_valid)begin
    m_count<=table_count;
    if(table_tag!=m_tag)fail_packet(5);
    else if(table_status==1&&!table_found)fail_packet(4);
    else if(table_status!=0||!table_found||table_inserted)fail_packet(5);
    else begin
     m_next_hop<=table_value[31:0]==0?header_q[31:0]:table_value[31:0];
     m_port<=table_value[39:32];m_prefix<=table_prefix;m_prefix_length<=table_length;
     work_header<=header_q;work_header[95:88]<=header_q[95:88]-1'b1;
     work_header[79:64]<=0;generate_sum<=1;pair_index<=0;state<=SUM_SEND;
    end
   end
   OUTPUT:if(m_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
 generate if(ROUTES<1||ROUTES>128||TAG_W<1||TAG_W>32)begin:invalid_parameters
  ipv4_lpm_forward_invalid_parameters__see_README rejected();
 end endgenerate
endmodule
