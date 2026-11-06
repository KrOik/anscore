// NHWC scalar depthwise CNN cross-correlation, VALID stride/dilation one.
// Public reset is synchronous high. Child RAM response controls also assert
// asynchronously from !rst; payload RAM and horizontal histories are unreset.
module int4_depthwise3x3_stream #(
 parameter MAX_CHANNELS=4, MAX_WIDTH=64, MAX_HEIGHT=64, TAG_W=16
)(
 input wire clk,rst,
 input wire c_valid, output wire c_ready,
 input wire [1:0] c_op, input wire [31:0] c_channel,c_word,c_weights,
 input wire [31:0] c_bias, input wire [15:0] c_scale,
 input wire [4:0] c_shift, input wire [7:0] c_zero,
 output wire c_rsp_valid, input wire c_rsp_ready, output reg [1:0] c_rsp_error,
 input wire cmd_valid, output wire cmd_ready,
 input wire [31:0] cmd_width,cmd_height,cmd_channels,
 input wire [7:0] cmd_x_zero, input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid, output wire s_ready, input wire [7:0] s_data,
 input wire s_sof,s_eol,s_last,
 output wire m_valid, input wire m_ready, output reg [7:0] m_data,
 output reg m_clip,m_inexact,
 output wire [31:0] m_x,m_y,m_channel,
 output wire m_sof,m_eol,m_last, output wire [TAG_W-1:0] m_tag,
 output wire rsp_valid,input wire rsp_ready,
 output reg [2:0] rsp_error,output reg [31:0] rsp_outputs,
 output wire [TAG_W-1:0] rsp_tag
);
 localparam XW=$clog2(MAX_WIDTH+1), YW=$clog2(MAX_HEIGHT+1);
 localparam CW=(MAX_CHANNELS<2)?1:$clog2(MAX_CHANNELS+1);
 localparam LD=MAX_WIDTH*MAX_CHANNELS, LA=(LD<2)?1:$clog2(LD);
 localparam KA=(2*MAX_CHANNELS<2)?1:$clog2(2*MAX_CHANNELS);
 localparam MA=(MAX_CHANNELS<2)?1:$clog2(MAX_CHANNELS);
 localparam IDLE=0,CFG_REQ=1,CFG_ACK=2,CFG_RSP=3,PREFLIGHT=4,
  INPUT=5,LINE_READ=6,LINE_ACK=7,KERNEL_REQ=8,KERNEL_FIRST=9,
  KERNEL_SECOND=10,MAC=11,SCALE=12,QUANT_REQ=13,QUANT_WAIT=14,
  OUTPUT=15,DONE=16;
 reg [4:0] state;
 reg [MAX_CHANNELS-1:0] valid0,valid1,validmeta;
 reg [CW-1:0] check_channel,channel,channels;
 reg [XW-1:0] width,x;
 reg [YW-1:0] height,y;
 reg [7:0] x_zero,sample;
 reg [TAG_W-1:0] tag;
 reg marker_error;
 reg [LA-1:0] line_addr;
 reg [7:0] top1[0:MAX_CHANNELS-1],top2[0:MAX_CHANNELS-1];
 reg [7:0] mid1[0:MAX_CHANNELS-1],mid2[0:MAX_CHANNELS-1];
 reg [7:0] bot1[0:MAX_CHANNELS-1],bot2[0:MAX_CHANNELS-1];
 reg [71:0] window;
 reg [35:0] weights;
 reg signed [32:0] accumulator;
 reg [15:0] scale;
 reg [4:0] shift;
 reg [7:0] zero;
 reg [3:0] tap;
 reg signed [49:0] scaled;
 reg [1:0] cfg_op;
 reg [CW-1:0] cfg_channel;
 reg cfg_word;
 reg [31:0] cfg_weights;
 reg [63:0] cfg_meta;
 wire l1_ready,l2_ready,l1_valid,l2_valid,l1_error,l2_error;
 wire [7:0] l1_data,l2_data;
 wire k_ready,k_valid,k_error,meta_ready,meta_valid,meta_error;
 wire [31:0] k_data;
 wire [63:0] meta_data;
 wire rows_ok=l1_valid && l2_valid && !l1_error && !l2_error;
 wire take_sample=s_valid && s_ready;
 wire line_write=(state==LINE_READ) && rows_ok;
 wire line_req=take_sample || line_write;
 wire [7:0] top_now=(y>=2)?l2_data:8'd0;
 wire [7:0] mid_now=(y>=1)?l1_data:8'd0;
 wire cfg_k=(state==CFG_REQ && cfg_op==0);
 wire cfg_m=(state==CFG_REQ && cfg_op==1);
 wire kernel_first_req=(state==KERNEL_REQ);
 wire kernel_second_req=(state==KERNEL_FIRST && k_valid && meta_valid && !k_error && !meta_error);
 wire k_req=cfg_k || kernel_first_req || kernel_second_req;
 wire [KA-1:0] k_addr=(state==CFG_REQ)?((cfg_channel<<1)|cfg_word):((channel<<1)|kernel_second_req);
 wire meta_req=cfg_m || kernel_first_req;
 wire [MA-1:0] meta_addr=(state==CFG_REQ)?cfg_channel:channel;
 wire q_ready,q_valid,q_clip,q_inexact;
 wire [15:0] q_data;
 wire [TAG_W-1:0] q_tag;
 wire signed [8:0] delta=$signed({1'b0,window[tap*8 +: 8]})-$signed({1'b0,x_zero});
 wire signed [3:0] weight=$signed(weights[tap*4 +: 4]);
 wire signed [12:0] product=delta*weight;
 wire signed [32:0] product_ext={{20{product[12]}},product};
 wire signed [16:0] q_plus_zero=$signed({q_data[15],q_data})+$signed({{9{zero[7]}},zero});
 wire last_channel=(channel==channels-1'b1);
 wire last_column=(x==width-1'b1);
 wire last_row=(y==height-1'b1);
 wire final_sample=last_channel && last_column && last_row;
 assign c_ready=!rst && state==IDLE;
 assign cmd_ready=!rst && state==IDLE && !c_valid;
 assign c_rsp_valid=!rst && state==CFG_RSP;
 assign s_ready=!rst && state==INPUT && l1_ready && l2_ready;
 assign m_valid=!rst && state==OUTPUT;
 assign m_x=x-2; assign m_y=y-2; assign m_channel=channel;
 assign m_sof=(x==2 && y==2 && channel==0);
 assign m_eol=last_column && last_channel;
 assign m_last=final_sample;
 assign m_tag=tag; assign rsp_tag=tag;
 assign rsp_valid=!rst && state==DONE;

 cip_sync_sp_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(LA),.DEPTH(LD)) line1(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(line_req),.req_ready(l1_ready),
  .req_write(line_write),.req_addr(line_addr),.req_wdata(sample),.req_wstrb(1'b1),
  .rsp_valid(l1_valid),.rsp_ready(1'b1),.rsp_rdata(l1_data),.rsp_error(l1_error));
 cip_sync_sp_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(LA),.DEPTH(LD)) line2(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(line_req),.req_ready(l2_ready),
  .req_write(line_write),.req_addr(line_addr),.req_wdata(mid_now),.req_wstrb(1'b1),
  .rsp_valid(l2_valid),.rsp_ready(1'b1),.rsp_rdata(l2_data),.rsp_error(l2_error));
 cip_sync_sp_ram #(.DATA_WIDTH(32),.ADDR_WIDTH(KA),.DEPTH(2*MAX_CHANNELS)) kernels(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(k_req),.req_ready(k_ready),
  .req_write(cfg_k),.req_addr(k_addr),.req_wdata(cfg_weights),.req_wstrb(4'hf),
  .rsp_valid(k_valid),.rsp_ready(1'b1),.rsp_rdata(k_data),.rsp_error(k_error));
 cip_sync_sp_ram #(.DATA_WIDTH(64),.ADDR_WIDTH(MA),.DEPTH(MAX_CHANNELS)) metadata(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),.req_valid(meta_req),.req_ready(meta_ready),
  .req_write(cfg_m),.req_addr(meta_addr),.req_wdata(cfg_meta),.req_wstrb(8'hff),
  .rsp_valid(meta_valid),.rsp_ready(1'b1),.rsp_rdata(meta_data),.rsp_error(meta_error));
 stream_requantize #(.IN_W(64),.OUT_W(16),.TAG_W(TAG_W)) quantizer(
  .clk(clk),.rst(rst),.s_valid(state==QUANT_REQ && !rst),.s_ready(q_ready),
  .s_data({{14{scaled[49]}},scaled}),.s_shift({2'b0,shift}),.s_tag(tag),
  .m_valid(q_valid),.m_ready(state==QUANT_WAIT),.m_data(q_data),
  .m_clip(q_clip),.m_inexact(q_inexact),.m_tag(q_tag));

 // Only called after the scalar's row write or its external output retires.
 task advance_sample;
 begin
  if(last_channel)begin
   channel<=0;
   if(last_column)begin x<=0;y<=y+1'b1;line_addr<=0;end
   else begin x<=x+1'b1;line_addr<=line_addr+1'b1;end
  end else begin channel<=channel+1'b1;line_addr<=line_addr+1'b1;end
  state<=INPUT;
 end
 endtask
 task abort_frame;
 begin
  valid0<=0;valid1<=0;validmeta<=0;rsp_error<=4;state<=DONE;
 end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;valid0<=0;valid1<=0;validmeta<=0;
   rsp_error<=0;rsp_outputs<=0;c_rsp_error<=0;
  end else case(state)
   IDLE:begin
    if(c_valid)begin
     c_rsp_error<=0;
     if(c_op==3)begin c_rsp_error<=2;state<=CFG_RSP;end
     else if(c_op==2)begin valid0<=0;valid1<=0;validmeta<=0;state<=CFG_RSP;end
     else if(c_channel>=MAX_CHANNELS || (c_op==0 && c_word>1))begin
      c_rsp_error<=1;state<=CFG_RSP;
     end else begin
      cfg_op<=c_op;cfg_channel<=c_channel[CW-1:0];cfg_word<=c_word[0];
      cfg_weights<=c_weights;cfg_meta<={3'b0,c_bias,c_scale,c_shift,c_zero};state<=CFG_REQ;
     end
    end else if(cmd_valid)begin
     tag<=cmd_tag;rsp_outputs<=0;rsp_error<=0;marker_error<=0;
     if(cmd_width<3 || cmd_width>MAX_WIDTH || cmd_height<3 || cmd_height>MAX_HEIGHT ||
        cmd_channels<1 || cmd_channels>MAX_CHANNELS)begin rsp_error<=1;state<=DONE;end
     else begin
      width<=cmd_width[XW-1:0];height<=cmd_height[YW-1:0];channels<=cmd_channels[CW-1:0];
      x_zero<=cmd_x_zero;check_channel<=0;channel<=0;x<=0;y<=0;line_addr<=0;state<=PREFLIGHT;
     end
    end
   end
   CFG_REQ:begin
    if((cfg_op==0 && !k_ready)||(cfg_op==1 && !meta_ready))begin
     valid0<=0;valid1<=0;validmeta<=0;c_rsp_error<=3;state<=CFG_RSP;
    end else state<=CFG_ACK;
   end
   CFG_ACK:begin
    if((cfg_op==0 && (!k_valid || k_error))||(cfg_op==1 && (!meta_valid || meta_error)))begin
     valid0<=0;valid1<=0;validmeta<=0;c_rsp_error<=3;
    end else if(cfg_op==1)validmeta[cfg_channel]<=1;
    else if(cfg_word)valid1[cfg_channel]<=1;
    else valid0[cfg_channel]<=1;
    state<=CFG_RSP;
   end
   CFG_RSP:if(c_rsp_ready)state<=IDLE;
   PREFLIGHT:begin
    if(!valid0[check_channel] || !valid1[check_channel] || !validmeta[check_channel])begin
     rsp_error<=2;state<=DONE;
    end else if(check_channel==channels-1'b1)state<=INPUT;
    else check_channel<=check_channel+1'b1;
   end
   INPUT:if(take_sample)begin
    sample<=s_data;
    if(s_sof!=(x==0 && y==0 && channel==0) || s_eol!=(last_column && last_channel) || s_last!=final_sample)
     marker_error<=1;
    state<=LINE_READ;
   end
   LINE_READ:begin
    if(!rows_ok || !l1_ready || !l2_ready)abort_frame;
    else begin
     window<={sample,bot1[channel],bot2[channel],mid_now,mid1[channel],mid2[channel],top_now,top1[channel],top2[channel]};
     top2[channel]<=top1[channel];top1[channel]<=top_now;
     mid2[channel]<=mid1[channel];mid1[channel]<=mid_now;
     bot2[channel]<=bot1[channel];bot1[channel]<=sample;
     state<=LINE_ACK;
    end
   end
   LINE_ACK:begin
    if(!rows_ok)abort_frame;
    else if(x>=2 && y>=2)state<=KERNEL_REQ;
    else advance_sample;
   end
   KERNEL_REQ:begin
    if(!k_ready || !meta_ready)abort_frame;
    else state<=KERNEL_FIRST;
   end
   KERNEL_FIRST:begin
    if(!k_valid || !meta_valid || k_error || meta_error || !k_ready)abort_frame;
    else begin
     weights[31:0]<=k_data;
     accumulator<={meta_data[60],meta_data[60:29]};
     scale<=meta_data[28:13];shift<=meta_data[12:8];zero<=meta_data[7:0];
     state<=KERNEL_SECOND;
    end
   end
   KERNEL_SECOND:begin
    if(!k_valid || k_error)abort_frame;
    else begin weights[35:32]<=k_data[3:0];tap<=0;state<=MAC;end
   end
   MAC:begin
    accumulator<=accumulator+product_ext;
    if(tap==8)state<=SCALE;else tap<=tap+1'b1;
   end
   SCALE:begin scaled<=accumulator*$signed({1'b0,scale});state<=QUANT_REQ;end
   QUANT_REQ:if(q_ready)state<=QUANT_WAIT;
   QUANT_WAIT:if(q_valid)begin
    if(q_tag!=tag)abort_frame;
    else begin
     m_data<=q_plus_zero>127?8'h7f:q_plus_zero< -128?8'h80:q_plus_zero[7:0];
     m_clip<=q_clip || q_plus_zero>127 || q_plus_zero< -128;m_inexact<=q_inexact;state<=OUTPUT;
    end
   end
   OUTPUT:if(m_ready)begin
    rsp_outputs<=rsp_outputs+1'b1;
    if(final_sample)begin rsp_error<=marker_error?3:0;state<=DONE;end
    else advance_sample;
   end
   DONE:if(rsp_ready)state<=IDLE;
   default:abort_frame;
  endcase
 end
 generate if(MAX_CHANNELS<1 || MAX_CHANNELS>16 || MAX_WIDTH<3 || MAX_WIDTH>1024 ||
             MAX_HEIGHT<3 || MAX_HEIGHT>1024 || TAG_W<1 || TAG_W>32)begin: invalid_parameters
  INT4_DEPTHWISE3X3_STREAM_UNSUPPORTED_PARAMETERS error();
 end endgenerate
endmodule
