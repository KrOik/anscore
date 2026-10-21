// Functional bounded programmable subpixel CNN inference frame adapter; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_super_resolution #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64, parameter FEATURES=4)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [TAG_W-1:0] cmd_tag,
    output wire rsp_valid,
    input wire rsp_ready,
    output reg [TAG_W-1:0] rsp_tag,
    output reg [1:0] rsp_error,
    input wire [15:0] cfg_src_width, cfg_src_height,
    input wire [15:0] cfg_dst_width, cfg_dst_height,
    input wire [3:0] cfg_mode,
    input wire [31:0] cfg_param0, cfg_param1,
    input wire [31:0] cfg_frame_base, cfg_frame_stride,
    input wire [31:0] cfg_aux_base,
    input wire coeff_valid,
    output wire coeff_ready,
    input wire [15:0] coeff_addr,
    input wire [31:0] coeff_data,
    input wire [DATA_W-1:0] aux_data,
    input wire aux_valid, aux_sof, aux_eol,
    output wire aux_ready,
    output wire mem_req_valid, mem_req_write,
    output wire [31:0] mem_req_addr, mem_req_wdata,
    output wire [3:0] mem_req_wstrb,
    input wire mem_req_ready, mem_rsp_valid,
    input wire [31:0] mem_rsp_rdata,
    input wire mem_rsp_error,
    output wire mem_rsp_ready,
    input wire s_sof, s_eol,
    output wire m_sof, m_eol,
    input wire [DATA_W-1:0] s_data,
    input wire s_valid,
    output wire s_ready,
    output wire [DATA_W-1:0] m_data,
    output wire m_valid,
    input wire m_ready
);
// Compact four-convolution/ReLU/subpixel2x network, scalar gray8.
// Shape: 1->F (5x5), F->F (3x3), F->F (3x3), F->4 (3x3), PixelShuffle2.
// All convolutions use zero padding. This is programmable inference, no pretrained
// image-quality claim. Load a trained/quantized model before inference.
// mode0 loads MODEL_WORDS words at unique coefficient addresses; mode1 infers.
// Weight entries are sign-extended16-bit Q8; bias entries signed32-bit Q8.
localparam W1=FEATURES*25,B1=W1,W2=B1+FEATURES,B2=W2+9*FEATURES*FEATURES;
localparam W3=B2+FEATURES,B3=W3+9*FEATURES*FEATURES,W4=B3+FEATURES,B4=W4+9*FEATURES*4;
localparam MODEL_WORDS=B4+4,DEPTH=MAX_WIDTH*MAX_HEIGHT;
localparam IDLE=0,LOAD=1,CAPTURE=2,BIAS_READ=3,BIAS_SET=4,TERM_READ=5,MAC=6,QUANTIZE=7,SEND=8,RESPONSE=9;
localparam SUPPORTED=DATA_W>=8 && DATA_W<=32 && FEATURES>=1 && FEATURES<=16 && MAX_WIDTH>=1 && MAX_HEIGHT>=1 &&
 MAX_WIDTH<=32767 && MAX_HEIGHT<=32767 && 64'd1*MAX_WIDTH*MAX_HEIGHT<=1048576;
reg [3:0] state;
reg active_bank,model_valid,load_error,frame_error;
reg [MODEL_WORDS-1:0] seen;
localparam COUNT_W=$clog2(MODEL_WORDS+1),MODEL_AW=$clog2(MODEL_WORDS);
localparam FEATURE_W=FEATURES<2?1:$clog2(FEATURES);
localparam WIDTH_W=MAX_WIDTH<2?1:$clog2(MAX_WIDTH+1),HEIGHT_W=MAX_HEIGHT<2?1:$clog2(MAX_HEIGHT+1);
localparam X_W=MAX_WIDTH<2?1:$clog2(2*MAX_WIDTH),Y_W=MAX_HEIGHT<2?1:$clog2(2*MAX_HEIGHT);
localparam SX_W=$clog2(MAX_WIDTH+3)+1,SY_W=$clog2(MAX_HEIGHT+3)+1;
localparam FRAME_AW=DEPTH<2?1:$clog2(DEPTH),HIDDEN_AW=DEPTH*FEATURES<2?1:$clog2(DEPTH*FEATURES);
reg [COUNT_W-1:0] received;
reg [WIDTH_W-1:0] width;reg [HEIGHT_W-1:0] height;
reg [X_W-1:0] x;reg [Y_W-1:0] y;
reg [1:0] layer;
reg [FEATURE_W-1:0] oc,ic;
reg [4:0] tap;
reg [2:0] tap_x,tap_y;
reg [31:0] coefficient_q;
reg [15:0] sample_q;
reg signed [47:0] accumulator;
reg [7:0] output_pixel;
(* ram_style="block",syn_ramstyle="block_ram" *) reg [31:0] coefficients[0:2*MODEL_WORDS-1];
reg [7:0] frame_ram[0:DEPTH-1];
reg [15:0] hidden1[0:DEPTH*FEATURES-1],hidden2[0:DEPTH*FEATURES-1],hidden3[0:DEPTH*FEATURES-1];
reg [MODEL_AW-1:0] weight_base,bias_base,weight_index;
reg [X_W-1:0] cx;reg [Y_W-1:0] cy;
reg signed [SX_W-1:0] sx;reg signed [SY_W-1:0] sy;
reg [FRAME_AW-1:0] source_index;
reg [HIDDEN_AW-1:0] feature_index;
wire [3:0] final_channel={2'b0,y[0],x[0]};
wire last_term=(layer==0 || ic==FEATURES-1) && (layer==0?tap==24:tap==8);
wire last_pixel=x==width-1'b1 && y==height-1'b1;
wire last_output=x==({1'b0,width}*2)-1 && y==({1'b0,height}*2)-1;
wire coefficient_is_bias=(coeff_addr>=B1 && coeff_addr<W2) || (coeff_addr>=B2 && coeff_addr<W3) ||
 (coeff_addr>=B3 && coeff_addr<W4) || coeff_addr>=B4;
wire bad_coefficient=coeff_addr>=MODEL_WORDS || (coeff_addr<MODEL_WORDS && seen[coeff_addr]) ||
 (!coefficient_is_bias && coeff_data!={{16{coeff_data[15]}},coeff_data[15:0]});
wire common_bad=!SUPPORTED || cfg_param0!=0 || cfg_param1!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
wire load_bad=common_bad || cfg_src_width!=0 || cfg_src_height!=0 || cfg_dst_width!=0 || cfg_dst_height!=0;
wire frame_bad=common_bad || !model_valid || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH ||
 cfg_src_height>MAX_HEIGHT || cfg_dst_width!=32'd2*cfg_src_width || cfg_dst_height!=32'd2*cfg_src_height;
wire signed [16:0] positive_sample=$signed({1'b0,sample_q});
wire signed [32:0] product=positive_sample*$signed(coefficient_q[15:0]);
wire signed [47:0] shifted=($signed(accumulator)+48'sd128)>>>8;
wire [15:0] hidden_value=shifted<0?16'd0:(shifted>65535?16'hffff:shifted[15:0]);
wire [7:0] final_value=shifted<0?8'd0:(shifted>255?8'hff:shifted[7:0]);
wire [FRAME_AW-1:0] capture_index=y*width+x;
// Exactly one synchronous coefficient read port for both bias and term fetch.
// The active bank changes only after a complete validated model transaction.
wire [MODEL_AW:0] coefficient_read_address=(active_bank?MODEL_WORDS:0)+
 (state==BIAS_READ?bias_base+(layer==3?final_channel:oc):weight_index);
wire [MODEL_AW:0] coefficient_write_address=(active_bank?0:MODEL_WORDS)+coeff_addr[MODEL_AW-1:0];
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign coeff_ready=rst_n && state==LOAD;
assign s_ready=rst_n && state==CAPTURE;
assign m_valid=rst_n && state==SEND;
assign m_data=output_pixel;
assign m_sof=m_valid && x==0 && y==0;
assign m_eol=m_valid && x==({1'b0,width}*2)-1;
assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @*begin
 weight_base=layer==0?0:(layer==1?W2:(layer==2?W3:W4));
 bias_base=layer==0?B1:(layer==1?B2:(layer==2?B3:B4));
 cx=layer==3?(x>>1):x;cy=layer==3?(y>>1):y;
 sx=cx+tap_x-(layer==0?2:1);sy=cy+tap_y-(layer==0?2:1);
 source_index=sy*width+sx;
 feature_index=(y*width+x)*FEATURES+oc;
 if(layer==0)weight_index=oc*25+tap;
 else weight_index=weight_base+((layer==3?final_channel:oc)*FEATURES+ic)*9+tap;
end
// No reset on frame/features/model memories. All reads are registered.
always @(posedge clk)if(rst_n && clk_en)begin
 if(state==LOAD && coeff_valid && coeff_ready && coeff_addr<MODEL_WORDS)
  coefficients[coefficient_write_address]<=coeff_data;
 if(state==CAPTURE && s_valid && s_ready)frame_ram[capture_index]<=s_data[7:0];
 if(state==BIAS_READ || state==TERM_READ)coefficient_q<=coefficients[coefficient_read_address];
 if(state==TERM_READ)begin
  if(sx<0 || sy<0 || sx>=width || sy>=height)sample_q<=0;
  else case(layer)
   0:sample_q<=frame_ram[source_index];
   1:sample_q<=hidden1[source_index*FEATURES+ic];
   2:sample_q<=hidden2[source_index*FEATURES+ic];
   3:sample_q<=hidden3[source_index*FEATURES+ic];
  endcase
 end
 if(state==QUANTIZE)case(layer)
  0:hidden1[feature_index]<=hidden_value;
  1:hidden2[feature_index]<=hidden_value;
  2:hidden3[feature_index]<=hidden_value;
 endcase
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;active_bank<=0;model_valid<=0;load_error<=0;frame_error<=0;seen<=0;received<=0;
 width<=0;height<=0;x<=0;y<=0;layer<=0;oc<=0;ic<=0;tap<=0;tap_x<=0;tap_y<=0;accumulator<=0;output_pixel<=0;rsp_tag<=0;rsp_error<=0;end
 else if(clk_en)begin
  case(state)
   IDLE:if(cmd_valid)begin
    rsp_tag<=cmd_tag;rsp_error<=0;frame_error<=0;
    if(cfg_mode>1)begin state<=RESPONSE;rsp_error<=1;end
    else if(cfg_mode==0)begin
     if(load_bad)begin state<=RESPONSE;rsp_error<=2;end
     else begin state<=LOAD;seen<=0;received<=0;load_error<=0;end
    end else if(frame_bad)begin state<=RESPONSE;rsp_error<=2;end
    else begin state<=CAPTURE;width<=cfg_src_width;height<=cfg_src_height;x<=0;y<=0;end
   end
   LOAD:if(coeff_valid && coeff_ready)begin
    received<=received+1;
    if(bad_coefficient)load_error<=1;
    if(coeff_addr<MODEL_WORDS)seen[coeff_addr]<=1;
    if(received==MODEL_WORDS-1)begin
     if(load_error || bad_coefficient || ((seen | ({{(MODEL_WORDS-1){1'b0}},1'b1}<<coeff_addr))!={MODEL_WORDS{1'b1}}))rsp_error<=2;
     else begin active_bank<=!active_bank;model_valid<=1;end
     state<=RESPONSE;
    end
   end
   CAPTURE:if(s_valid && s_ready)begin
    if(s_sof!=(x==0 && y==0) || s_eol!=(x==width-1'b1) || (s_data>>8)!=0)frame_error<=1;
    if(last_pixel)begin
     x<=0;y<=0;oc<=0;layer<=0;
     if(frame_error || s_sof!=(x==0 && y==0) || s_eol!=(x==width-1'b1) || (s_data>>8)!=0)begin state<=RESPONSE;rsp_error<=2;end
     else state<=BIAS_READ;
    end else if(x==width-1'b1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
   end
   BIAS_READ:state<=BIAS_SET;
   BIAS_SET:begin accumulator<={{16{coefficient_q[31]}},coefficient_q};tap<=0;tap_x<=0;tap_y<=0;ic<=0;state<=TERM_READ;end
   TERM_READ:state<=MAC;
   MAC:begin
    accumulator<=accumulator+{{15{product[32]}},product};
    if(last_term)state<=QUANTIZE;
    else begin
     if(layer==0?tap==24:tap==8)begin tap<=0;tap_x<=0;tap_y<=0;ic<=ic+1;end
     else begin
      tap<=tap+1;
      if(tap_x==(layer==0?4:2))begin tap_x<=0;tap_y<=tap_y+1'b1;end
      else tap_x<=tap_x+1'b1;
     end
     state<=TERM_READ;
    end
   end
   QUANTIZE:begin
    if(layer==3)begin output_pixel<=final_value;state<=SEND;end
    else begin
     state<=BIAS_READ;
     if(oc==FEATURES-1)begin
      oc<=0;
      if(last_pixel)begin layer<=layer+1'b1;x<=0;y<=0;end
      else if(x==width-1'b1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
     end else oc<=oc+1;
    end
   end
   SEND:if(m_ready)begin
    if(last_output)state<=RESPONSE;
    else begin
     if(x==({1'b0,width}*2)-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
     state<=BIAS_READ;
    end
   end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin state<=RESPONSE;rsp_error<=3;end
  endcase
 end
end
endmodule
