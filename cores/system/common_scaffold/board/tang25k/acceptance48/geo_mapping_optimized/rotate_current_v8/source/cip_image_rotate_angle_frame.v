// Centered inverse rotation using validated signed Q16.16 cosine/sine.
module cip_image_rotate_angle_frame #(
 parameter DATA_W=24,TAG_W=8,MAX_WIDTH=64,MAX_HEIGHT=64,PIXEL_W=8
)(
 input wire clk,rst_n,clk_en,
 input wire cmd_valid,output wire cmd_ready,input wire [TAG_W-1:0] cmd_tag,
 input wire [15:0] cfg_width,cfg_height,cfg_dst_width,cfg_dst_height,
 input wire cfg_bilinear,input wire signed [31:0] cfg_cos,cfg_sin,
 output wire rsp_valid,input wire rsp_ready,output reg [TAG_W-1:0] rsp_tag,
 output reg [1:0] rsp_error,
 input wire [DATA_W-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire [DATA_W-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready
);
// Configuration arithmetic is iterative and fully captured on command acceptance.
localparam IDLE=0,START=1,RUN=2,RESPONSE=3,MUL_START=4,MUL_WAIT=5,SUM_BYTES=6,COMMIT=7;
localparam LANES=DATA_W/(PIXEL_W>0?PIXEL_W:1);
localparam SUPPORTED=PIXEL_W>=1 && PIXEL_W<=16 && DATA_W>=PIXEL_W && DATA_W<=32 &&
 DATA_W==PIXEL_W*LANES && MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 &&
 (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
reg [2:0] state;
reg [15:0] sw,sh,dw,dh;
reg filter_mode;
reg signed [31:0] cosine,sine,offset_x,offset_y;
wire signed [17:0] neg_cos=-$signed(cosine[17:0]);
wire signed [17:0] neg_sin=-$signed(sine[17:0]);
wire [16:0] abs_cos=cosine[31] ? (17'd0-cosine[16:0]) : cosine[16:0];
wire [16:0] abs_sin=sine[31] ? (17'd0-sine[16:0]) : sine[16:0];
wire [15:0] dx=dw-16'd1,dy=dh-16'd1;
wire core_ready,core_rv,core_sr,core_mv,core_ms,core_me,core_last;
wire [3:0] core_error;
wire [DATA_W-1:0] core_data;
wire bad_config=!SUPPORTED || cfg_width==0 || cfg_height==0 ||
 cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT || cfg_dst_width==0 || cfg_dst_height==0 ||
 cfg_cos < -32'sd65536 || cfg_cos>32'sd65536 || cfg_sin < -32'sd65536 || cfg_sin>32'sd65536;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && core_mv;
assign m_data=core_data;
assign m_sof=m_valid && core_ms;
assign m_eol=m_valid && core_me;
assign m_last=m_valid && core_last;
wire [48:0] product_cx;wire ready_cx,valid_cx;
cip_rotate_config_product mul_cx(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
 .s_valid(state==MUL_START),.s_ready(ready_cx),.s_a({{14{neg_cos[17]}},neg_cos}),.s_b({1'b0,dx}),
 .m_valid(valid_cx),.m_ready(state==MUL_WAIT),.m_product(product_cx));
wire [48:0] product_sy;wire ready_sy,valid_sy;
cip_rotate_config_product mul_sy(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
 .s_valid(state==MUL_START),.s_ready(ready_sy),.s_a({{14{neg_sin[17]}},neg_sin}),.s_b({1'b0,dy}),
 .m_valid(valid_sy),.m_ready(state==MUL_WAIT),.m_product(product_sy));
wire [48:0] product_sx;wire ready_sx,valid_sx;
cip_rotate_config_product mul_sx(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
 .s_valid(state==MUL_START),.s_ready(ready_sx),.s_a(sine),.s_b({1'b0,dx}),
 .m_valid(valid_sx),.m_ready(state==MUL_WAIT),.m_product(product_sx));
wire [48:0] product_cy;wire ready_cy,valid_cy;
cip_rotate_config_product mul_cy(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
 .s_valid(state==MUL_START),.s_ready(ready_cy),.s_a({{14{neg_cos[17]}},neg_cos}),.s_b({1'b0,dy}),
 .m_valid(valid_cy),.m_ready(state==MUL_WAIT),.m_product(product_cy));
wire [48:0] product_cc;wire ready_cc,valid_cc;
cip_rotate_config_product mul_cc(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
 .s_valid(state==MUL_START),.s_ready(ready_cc),.s_a({15'd0,abs_cos}),.s_b(abs_cos),
 .m_valid(valid_cc),.m_ready(state==MUL_WAIT),.m_product(product_cc));
wire [48:0] product_ss;wire ready_ss,valid_ss;
cip_rotate_config_product mul_ss(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
 .s_valid(state==MUL_START),.s_ready(ready_ss),.s_a({15'd0,abs_sin}),.s_b(abs_sin),
 .m_valid(valid_ss),.m_ready(state==MUL_WAIT),.m_product(product_ss));
wire [49:0] cfg_x_a={18'd0,(sw-16'd1),16'd0},cfg_x_b={{1{product_cx[48]}},product_cx},cfg_x_c={{1{product_sy[48]}},product_sy};
wire [49:0] cfg_x_s=cfg_x_a ^ cfg_x_b ^ cfg_x_c;
wire [49:0] cfg_x_v=((cfg_x_a & cfg_x_b)|(cfg_x_a & cfg_x_c)|(cfg_x_b & cfg_x_c))<<1;
(* keep=1 *) reg [49:0] cfg_x_bytes;
(* keep=1 *) reg [6:0] cfg_x_g,cfg_x_p;
wire [7:0] cfg_x_carry;wire [49:0] cfg_x_result;
assign cfg_x_carry[0]=1'b0;
wire [8:0] cfg_x_add0={1'b0,cfg_x_s[7:0]}+{1'b0,cfg_x_v[7:0]};
assign cfg_x_carry[1]=cfg_x_g[0];
assign cfg_x_result[7:0]=cfg_x_bytes[7:0]+cfg_x_carry[0];
wire [8:0] cfg_x_add1={1'b0,cfg_x_s[15:8]}+{1'b0,cfg_x_v[15:8]};
assign cfg_x_carry[2]=cfg_x_g[1]|(cfg_x_p[1]&cfg_x_g[0]);
assign cfg_x_result[15:8]=cfg_x_bytes[15:8]+cfg_x_carry[1];
wire [8:0] cfg_x_add2={1'b0,cfg_x_s[23:16]}+{1'b0,cfg_x_v[23:16]};
assign cfg_x_carry[3]=cfg_x_g[2]|(cfg_x_p[2]&cfg_x_g[1])|(cfg_x_p[2]&cfg_x_p[1]&cfg_x_g[0]);
assign cfg_x_result[23:16]=cfg_x_bytes[23:16]+cfg_x_carry[2];
wire [8:0] cfg_x_add3={1'b0,cfg_x_s[31:24]}+{1'b0,cfg_x_v[31:24]};
assign cfg_x_carry[4]=cfg_x_g[3]|(cfg_x_p[3]&cfg_x_g[2])|(cfg_x_p[3]&cfg_x_p[2]&cfg_x_g[1])|(cfg_x_p[3]&cfg_x_p[2]&cfg_x_p[1]&cfg_x_g[0]);
assign cfg_x_result[31:24]=cfg_x_bytes[31:24]+cfg_x_carry[3];
wire [8:0] cfg_x_add4={1'b0,cfg_x_s[39:32]}+{1'b0,cfg_x_v[39:32]};
assign cfg_x_carry[5]=cfg_x_g[4]|(cfg_x_p[4]&cfg_x_g[3])|(cfg_x_p[4]&cfg_x_p[3]&cfg_x_g[2])|(cfg_x_p[4]&cfg_x_p[3]&cfg_x_p[2]&cfg_x_g[1])|(cfg_x_p[4]&cfg_x_p[3]&cfg_x_p[2]&cfg_x_p[1]&cfg_x_g[0]);
assign cfg_x_result[39:32]=cfg_x_bytes[39:32]+cfg_x_carry[4];
wire [8:0] cfg_x_add5={1'b0,cfg_x_s[47:40]}+{1'b0,cfg_x_v[47:40]};
assign cfg_x_carry[6]=cfg_x_g[5]|(cfg_x_p[5]&cfg_x_g[4])|(cfg_x_p[5]&cfg_x_p[4]&cfg_x_g[3])|(cfg_x_p[5]&cfg_x_p[4]&cfg_x_p[3]&cfg_x_g[2])|(cfg_x_p[5]&cfg_x_p[4]&cfg_x_p[3]&cfg_x_p[2]&cfg_x_g[1])|(cfg_x_p[5]&cfg_x_p[4]&cfg_x_p[3]&cfg_x_p[2]&cfg_x_p[1]&cfg_x_g[0]);
assign cfg_x_result[47:40]=cfg_x_bytes[47:40]+cfg_x_carry[5];
wire [2:0] cfg_x_add6={1'b0,cfg_x_s[49:48]}+{1'b0,cfg_x_v[49:48]};
assign cfg_x_carry[7]=cfg_x_g[6]|(cfg_x_p[6]&cfg_x_g[5])|(cfg_x_p[6]&cfg_x_p[5]&cfg_x_g[4])|(cfg_x_p[6]&cfg_x_p[5]&cfg_x_p[4]&cfg_x_g[3])|(cfg_x_p[6]&cfg_x_p[5]&cfg_x_p[4]&cfg_x_p[3]&cfg_x_g[2])|(cfg_x_p[6]&cfg_x_p[5]&cfg_x_p[4]&cfg_x_p[3]&cfg_x_p[2]&cfg_x_g[1])|(cfg_x_p[6]&cfg_x_p[5]&cfg_x_p[4]&cfg_x_p[3]&cfg_x_p[2]&cfg_x_p[1]&cfg_x_g[0]);
assign cfg_x_result[49:48]=cfg_x_bytes[49:48]+cfg_x_carry[6];
wire [49:0] cfg_y_a={18'd0,(sh-16'd1),16'd0},cfg_y_b={{1{product_sx[48]}},product_sx},cfg_y_c={{1{product_cy[48]}},product_cy};
wire [49:0] cfg_y_s=cfg_y_a ^ cfg_y_b ^ cfg_y_c;
wire [49:0] cfg_y_v=((cfg_y_a & cfg_y_b)|(cfg_y_a & cfg_y_c)|(cfg_y_b & cfg_y_c))<<1;
(* keep=1 *) reg [49:0] cfg_y_bytes;
(* keep=1 *) reg [6:0] cfg_y_g,cfg_y_p;
wire [7:0] cfg_y_carry;wire [49:0] cfg_y_result;
assign cfg_y_carry[0]=1'b0;
wire [8:0] cfg_y_add0={1'b0,cfg_y_s[7:0]}+{1'b0,cfg_y_v[7:0]};
assign cfg_y_carry[1]=cfg_y_g[0];
assign cfg_y_result[7:0]=cfg_y_bytes[7:0]+cfg_y_carry[0];
wire [8:0] cfg_y_add1={1'b0,cfg_y_s[15:8]}+{1'b0,cfg_y_v[15:8]};
assign cfg_y_carry[2]=cfg_y_g[1]|(cfg_y_p[1]&cfg_y_g[0]);
assign cfg_y_result[15:8]=cfg_y_bytes[15:8]+cfg_y_carry[1];
wire [8:0] cfg_y_add2={1'b0,cfg_y_s[23:16]}+{1'b0,cfg_y_v[23:16]};
assign cfg_y_carry[3]=cfg_y_g[2]|(cfg_y_p[2]&cfg_y_g[1])|(cfg_y_p[2]&cfg_y_p[1]&cfg_y_g[0]);
assign cfg_y_result[23:16]=cfg_y_bytes[23:16]+cfg_y_carry[2];
wire [8:0] cfg_y_add3={1'b0,cfg_y_s[31:24]}+{1'b0,cfg_y_v[31:24]};
assign cfg_y_carry[4]=cfg_y_g[3]|(cfg_y_p[3]&cfg_y_g[2])|(cfg_y_p[3]&cfg_y_p[2]&cfg_y_g[1])|(cfg_y_p[3]&cfg_y_p[2]&cfg_y_p[1]&cfg_y_g[0]);
assign cfg_y_result[31:24]=cfg_y_bytes[31:24]+cfg_y_carry[3];
wire [8:0] cfg_y_add4={1'b0,cfg_y_s[39:32]}+{1'b0,cfg_y_v[39:32]};
assign cfg_y_carry[5]=cfg_y_g[4]|(cfg_y_p[4]&cfg_y_g[3])|(cfg_y_p[4]&cfg_y_p[3]&cfg_y_g[2])|(cfg_y_p[4]&cfg_y_p[3]&cfg_y_p[2]&cfg_y_g[1])|(cfg_y_p[4]&cfg_y_p[3]&cfg_y_p[2]&cfg_y_p[1]&cfg_y_g[0]);
assign cfg_y_result[39:32]=cfg_y_bytes[39:32]+cfg_y_carry[4];
wire [8:0] cfg_y_add5={1'b0,cfg_y_s[47:40]}+{1'b0,cfg_y_v[47:40]};
assign cfg_y_carry[6]=cfg_y_g[5]|(cfg_y_p[5]&cfg_y_g[4])|(cfg_y_p[5]&cfg_y_p[4]&cfg_y_g[3])|(cfg_y_p[5]&cfg_y_p[4]&cfg_y_p[3]&cfg_y_g[2])|(cfg_y_p[5]&cfg_y_p[4]&cfg_y_p[3]&cfg_y_p[2]&cfg_y_g[1])|(cfg_y_p[5]&cfg_y_p[4]&cfg_y_p[3]&cfg_y_p[2]&cfg_y_p[1]&cfg_y_g[0]);
assign cfg_y_result[47:40]=cfg_y_bytes[47:40]+cfg_y_carry[5];
wire [2:0] cfg_y_add6={1'b0,cfg_y_s[49:48]}+{1'b0,cfg_y_v[49:48]};
assign cfg_y_carry[7]=cfg_y_g[6]|(cfg_y_p[6]&cfg_y_g[5])|(cfg_y_p[6]&cfg_y_p[5]&cfg_y_g[4])|(cfg_y_p[6]&cfg_y_p[5]&cfg_y_p[4]&cfg_y_g[3])|(cfg_y_p[6]&cfg_y_p[5]&cfg_y_p[4]&cfg_y_p[3]&cfg_y_g[2])|(cfg_y_p[6]&cfg_y_p[5]&cfg_y_p[4]&cfg_y_p[3]&cfg_y_p[2]&cfg_y_g[1])|(cfg_y_p[6]&cfg_y_p[5]&cfg_y_p[4]&cfg_y_p[3]&cfg_y_p[2]&cfg_y_p[1]&cfg_y_g[0]);
assign cfg_y_result[49:48]=cfg_y_bytes[49:48]+cfg_y_carry[6];
wire [49:0] cfg_n_a=50'd0,cfg_n_b={1'b0,product_cc},cfg_n_c={1'b0,product_ss};
wire [49:0] cfg_n_s=cfg_n_a ^ cfg_n_b ^ cfg_n_c;
wire [49:0] cfg_n_v=((cfg_n_a & cfg_n_b)|(cfg_n_a & cfg_n_c)|(cfg_n_b & cfg_n_c))<<1;
(* keep=1 *) reg [49:0] cfg_n_bytes;
(* keep=1 *) reg [6:0] cfg_n_g,cfg_n_p;
wire [7:0] cfg_n_carry;wire [49:0] cfg_n_result;
assign cfg_n_carry[0]=1'b0;
wire [8:0] cfg_n_add0={1'b0,cfg_n_s[7:0]}+{1'b0,cfg_n_v[7:0]};
assign cfg_n_carry[1]=cfg_n_g[0];
assign cfg_n_result[7:0]=cfg_n_bytes[7:0]+cfg_n_carry[0];
wire [8:0] cfg_n_add1={1'b0,cfg_n_s[15:8]}+{1'b0,cfg_n_v[15:8]};
assign cfg_n_carry[2]=cfg_n_g[1]|(cfg_n_p[1]&cfg_n_g[0]);
assign cfg_n_result[15:8]=cfg_n_bytes[15:8]+cfg_n_carry[1];
wire [8:0] cfg_n_add2={1'b0,cfg_n_s[23:16]}+{1'b0,cfg_n_v[23:16]};
assign cfg_n_carry[3]=cfg_n_g[2]|(cfg_n_p[2]&cfg_n_g[1])|(cfg_n_p[2]&cfg_n_p[1]&cfg_n_g[0]);
assign cfg_n_result[23:16]=cfg_n_bytes[23:16]+cfg_n_carry[2];
wire [8:0] cfg_n_add3={1'b0,cfg_n_s[31:24]}+{1'b0,cfg_n_v[31:24]};
assign cfg_n_carry[4]=cfg_n_g[3]|(cfg_n_p[3]&cfg_n_g[2])|(cfg_n_p[3]&cfg_n_p[2]&cfg_n_g[1])|(cfg_n_p[3]&cfg_n_p[2]&cfg_n_p[1]&cfg_n_g[0]);
assign cfg_n_result[31:24]=cfg_n_bytes[31:24]+cfg_n_carry[3];
wire [8:0] cfg_n_add4={1'b0,cfg_n_s[39:32]}+{1'b0,cfg_n_v[39:32]};
assign cfg_n_carry[5]=cfg_n_g[4]|(cfg_n_p[4]&cfg_n_g[3])|(cfg_n_p[4]&cfg_n_p[3]&cfg_n_g[2])|(cfg_n_p[4]&cfg_n_p[3]&cfg_n_p[2]&cfg_n_g[1])|(cfg_n_p[4]&cfg_n_p[3]&cfg_n_p[2]&cfg_n_p[1]&cfg_n_g[0]);
assign cfg_n_result[39:32]=cfg_n_bytes[39:32]+cfg_n_carry[4];
wire [8:0] cfg_n_add5={1'b0,cfg_n_s[47:40]}+{1'b0,cfg_n_v[47:40]};
assign cfg_n_carry[6]=cfg_n_g[5]|(cfg_n_p[5]&cfg_n_g[4])|(cfg_n_p[5]&cfg_n_p[4]&cfg_n_g[3])|(cfg_n_p[5]&cfg_n_p[4]&cfg_n_p[3]&cfg_n_g[2])|(cfg_n_p[5]&cfg_n_p[4]&cfg_n_p[3]&cfg_n_p[2]&cfg_n_g[1])|(cfg_n_p[5]&cfg_n_p[4]&cfg_n_p[3]&cfg_n_p[2]&cfg_n_p[1]&cfg_n_g[0]);
assign cfg_n_result[47:40]=cfg_n_bytes[47:40]+cfg_n_carry[5];
wire [2:0] cfg_n_add6={1'b0,cfg_n_s[49:48]}+{1'b0,cfg_n_v[49:48]};
assign cfg_n_carry[7]=cfg_n_g[6]|(cfg_n_p[6]&cfg_n_g[5])|(cfg_n_p[6]&cfg_n_p[5]&cfg_n_g[4])|(cfg_n_p[6]&cfg_n_p[5]&cfg_n_p[4]&cfg_n_g[3])|(cfg_n_p[6]&cfg_n_p[5]&cfg_n_p[4]&cfg_n_p[3]&cfg_n_g[2])|(cfg_n_p[6]&cfg_n_p[5]&cfg_n_p[4]&cfg_n_p[3]&cfg_n_p[2]&cfg_n_g[1])|(cfg_n_p[6]&cfg_n_p[5]&cfg_n_p[4]&cfg_n_p[3]&cfg_n_p[2]&cfg_n_p[1]&cfg_n_g[0]);
assign cfg_n_result[49:48]=cfg_n_bytes[49:48]+cfg_n_carry[6];
wire signed [49:0] tx=$signed(cfg_x_result)>>>1,ty=$signed(cfg_y_result)>>>1;
wire angle_bad=cfg_n_result<50'd4294836224 || cfg_n_result>50'd4295098368 ||
 tx < -50'sd2147483648 || tx>50'sd2147483647 || ty < -50'sd2147483648 || ty>50'sd2147483647;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;sw<=0;sh<=0;dw<=0;dh<=0;filter_mode<=0;cosine<=0;sine<=0;
  offset_x<=0;offset_y<=0;rsp_tag<=0;rsp_error<=0;
cfg_x_bytes<=0;cfg_x_g<=0;cfg_x_p<=0;
cfg_y_bytes<=0;cfg_y_g<=0;cfg_y_p<=0;
cfg_n_bytes<=0;cfg_n_g<=0;cfg_n_p<=0;
 end else if(clk_en)begin
  case(state)
   IDLE:if(cmd_valid && cmd_ready)begin
    rsp_tag<=cmd_tag;rsp_error<=0;
    if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
    else begin state<=MUL_START;sw<=cfg_width;sh<=cfg_height;dw<=cfg_dst_width;dh<=cfg_dst_height;
     filter_mode<=cfg_bilinear;cosine<=cfg_cos;sine<=cfg_sin;end
   end
   MUL_START:if(ready_cx && ready_sy && ready_sx && ready_cy && ready_cc && ready_ss)state<=MUL_WAIT;
   MUL_WAIT:if(valid_cx && valid_sy && valid_sx && valid_cy && valid_cc && valid_ss)state<=SUM_BYTES;
   SUM_BYTES:begin
cfg_x_bytes[7:0]<=cfg_x_add0[7:0];cfg_x_g[0]<=cfg_x_add0[8];cfg_x_p[0]<=&cfg_x_add0[7:0];
cfg_x_bytes[15:8]<=cfg_x_add1[7:0];cfg_x_g[1]<=cfg_x_add1[8];cfg_x_p[1]<=&cfg_x_add1[7:0];
cfg_x_bytes[23:16]<=cfg_x_add2[7:0];cfg_x_g[2]<=cfg_x_add2[8];cfg_x_p[2]<=&cfg_x_add2[7:0];
cfg_x_bytes[31:24]<=cfg_x_add3[7:0];cfg_x_g[3]<=cfg_x_add3[8];cfg_x_p[3]<=&cfg_x_add3[7:0];
cfg_x_bytes[39:32]<=cfg_x_add4[7:0];cfg_x_g[4]<=cfg_x_add4[8];cfg_x_p[4]<=&cfg_x_add4[7:0];
cfg_x_bytes[47:40]<=cfg_x_add5[7:0];cfg_x_g[5]<=cfg_x_add5[8];cfg_x_p[5]<=&cfg_x_add5[7:0];
cfg_x_bytes[49:48]<=cfg_x_add6[1:0];cfg_x_g[6]<=cfg_x_add6[2];cfg_x_p[6]<=&cfg_x_add6[1:0];
cfg_y_bytes[7:0]<=cfg_y_add0[7:0];cfg_y_g[0]<=cfg_y_add0[8];cfg_y_p[0]<=&cfg_y_add0[7:0];
cfg_y_bytes[15:8]<=cfg_y_add1[7:0];cfg_y_g[1]<=cfg_y_add1[8];cfg_y_p[1]<=&cfg_y_add1[7:0];
cfg_y_bytes[23:16]<=cfg_y_add2[7:0];cfg_y_g[2]<=cfg_y_add2[8];cfg_y_p[2]<=&cfg_y_add2[7:0];
cfg_y_bytes[31:24]<=cfg_y_add3[7:0];cfg_y_g[3]<=cfg_y_add3[8];cfg_y_p[3]<=&cfg_y_add3[7:0];
cfg_y_bytes[39:32]<=cfg_y_add4[7:0];cfg_y_g[4]<=cfg_y_add4[8];cfg_y_p[4]<=&cfg_y_add4[7:0];
cfg_y_bytes[47:40]<=cfg_y_add5[7:0];cfg_y_g[5]<=cfg_y_add5[8];cfg_y_p[5]<=&cfg_y_add5[7:0];
cfg_y_bytes[49:48]<=cfg_y_add6[1:0];cfg_y_g[6]<=cfg_y_add6[2];cfg_y_p[6]<=&cfg_y_add6[1:0];
cfg_n_bytes[7:0]<=cfg_n_add0[7:0];cfg_n_g[0]<=cfg_n_add0[8];cfg_n_p[0]<=&cfg_n_add0[7:0];
cfg_n_bytes[15:8]<=cfg_n_add1[7:0];cfg_n_g[1]<=cfg_n_add1[8];cfg_n_p[1]<=&cfg_n_add1[7:0];
cfg_n_bytes[23:16]<=cfg_n_add2[7:0];cfg_n_g[2]<=cfg_n_add2[8];cfg_n_p[2]<=&cfg_n_add2[7:0];
cfg_n_bytes[31:24]<=cfg_n_add3[7:0];cfg_n_g[3]<=cfg_n_add3[8];cfg_n_p[3]<=&cfg_n_add3[7:0];
cfg_n_bytes[39:32]<=cfg_n_add4[7:0];cfg_n_g[4]<=cfg_n_add4[8];cfg_n_p[4]<=&cfg_n_add4[7:0];
cfg_n_bytes[47:40]<=cfg_n_add5[7:0];cfg_n_g[5]<=cfg_n_add5[8];cfg_n_p[5]<=&cfg_n_add5[7:0];
cfg_n_bytes[49:48]<=cfg_n_add6[1:0];cfg_n_g[6]<=cfg_n_add6[2];cfg_n_p[6]<=&cfg_n_add6[1:0];
    state<=COMMIT;
   end
   COMMIT:begin
    if(angle_bad)begin state<=RESPONSE;rsp_error<=2;end
    else begin offset_x<=tx[31:0];offset_y<=ty[31:0];state<=START;end
   end
   START:if(core_ready)state<=RUN;
   RUN:if(core_rv)begin
    rsp_error<=core_error==0?2'd0:((core_error==1 || core_error==2)?2'd2:2'd3);
    state<=RESPONSE;
   end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin state<=RESPONSE;rsp_error<=3;end
  endcase
 end
end
generate if(SUPPORTED)begin:enabled
 img_geo_frame_buffered #(.PIXEL_W(PIXEL_W),.LANES(LANES),.TAG_W(TAG_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT)) core(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(state==START),.cfg_ready(core_ready),.cfg_tag(rsp_tag),
 .cfg_mode(4'd7),.cfg_filter({1'b0,filter_mode}),.cfg_src_width(sw),.cfg_src_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_h00(cosine),.cfg_h01(sine),.cfg_h02(offset_x),.cfg_h10(-sine),.cfg_h11(cosine),.cfg_h12(offset_y),
 .cfg_h20(32'sd0),.cfg_h21(32'sd0),.cfg_h22(32'sd65536),.busy(),
 .rsp_valid(core_rv),.rsp_ready(state==RUN),.rsp_tag(),.rsp_error(core_error),.rsp_pixels(),
 .s_valid(s_valid && state==RUN),.s_ready(core_sr),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(core_mv),.m_ready(m_ready && state==RUN),.m_data(core_data),.m_error(),.m_sof(core_ms),.m_eol(core_me),.m_eof(core_last));
end else begin:unsupported
 assign core_ready=0;assign core_rv=0;assign core_sr=0;assign core_mv=0;assign core_ms=0;assign core_me=0;assign core_last=0;assign core_data=0;assign core_error=0;
end endgenerate
endmodule

// Private exact signed32 x unsigned17 serial multiplier. No DSPs, CE-frozen handshake.
module cip_rotate_config_product(input wire clk,rst_n,clk_en,
 input wire s_valid,output wire s_ready,input wire signed [31:0] s_a,input wire [16:0] s_b,
 output reg m_valid,input wire m_ready,output reg [48:0] m_product);
localparam IDLE=0,ITER=1,FOLD=2,OUT=3;
reg [1:0] state;reg [4:0] count;reg [2:0] byte_index;
reg [48:0] shifted,sum,carry;reg [16:0] factor;reg byte_carry;
wire [48:0] addend=factor[0] ? shifted : 49'd0;
wire [8:0] folded=byte_index==6 ?
 ({8'd0,sum[48]}+{8'd0,carry[48]}+byte_carry):
 ({1'b0,sum[byte_index*8+:8]}+{1'b0,carry[byte_index*8+:8]}+byte_carry);
assign s_ready=rst_n && state==IDLE;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;count<=0;byte_index<=0;shifted<=0;sum<=0;carry<=0;factor<=0;
  byte_carry<=0;m_valid<=0;m_product<=0;end
 else if(clk_en)case(state)
  IDLE:if(s_valid && s_ready)begin shifted<={{17{s_a[31]}},s_a};factor<=s_b;
   sum<=0;carry<=0;count<=0;byte_carry<=0;m_valid<=0;state<=ITER;end
  ITER:begin
   sum<=sum ^ carry ^ addend;
   carry<=((sum & carry)|(sum & addend)|(carry & addend))<<1;
   shifted<=shifted<<1;factor<=factor>>1;
   if(count==16)begin byte_index<=0;state<=FOLD;end else count<=count+1'b1;
  end
  FOLD:begin
   case(byte_index)
    0:m_product[7:0]<=folded[7:0];1:m_product[15:8]<=folded[7:0];
    2:m_product[23:16]<=folded[7:0];3:m_product[31:24]<=folded[7:0];
    4:m_product[39:32]<=folded[7:0];5:m_product[47:40]<=folded[7:0];6:m_product[48]<=folded[0];
   endcase
   byte_carry<=folded[8];
   if(byte_index==6)begin m_valid<=1;state<=OUT;end else byte_index<=byte_index+1'b1;
  end
  OUT:if(m_valid && m_ready)begin m_valid<=0;state<=IDLE;end
 endcase
end
endmodule
