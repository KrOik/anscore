from pathlib import Path

HERE=Path(__file__).resolve().parent
old=(HERE/'geo_mapping_optimized/rotate_v6/source/cip_image_rotate_angle_frame.v').read_text()
head=old[:old.index('localparam IDLE=')]
support=old[old.index('localparam LANES='):old.index('reg [1:0] state;')]
core=old[old.index('generate if(SUPPORTED)'):]
text=head+'''// Configuration arithmetic is iterative and fully captured on command acceptance.
localparam IDLE=0,START=1,RUN=2,RESPONSE=3,MUL_START=4,MUL_WAIT=5,SUM_BYTES=6,COMMIT=7;
'''+support+'''reg [2:0] state;
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
'''
terms=[('cx','{{14{neg_cos[17]}},neg_cos}',"{1'b0,dx}"),
       ('sy','{{14{neg_sin[17]}},neg_sin}',"{1'b0,dy}"),
       ('sx','sine',"{1'b0,dx}"),('cy','{{14{neg_cos[17]}},neg_cos}',"{1'b0,dy}"),
       ('cc',"{15'd0,abs_cos}",'abs_cos'),('ss',"{15'd0,abs_sin}",'abs_sin')]
for n,a,b in terms:
 text+=f'''wire [48:0] product_{n};wire ready_{n},valid_{n};
cip_rotate_config_product mul_{n}(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),
 .s_valid(state==MUL_START),.s_ready(ready_{n}),.s_a({a}),.s_b({b}),
 .m_valid(valid_{n}),.m_ready(state==MUL_WAIT),.m_product(product_{n}));
'''
capture='';reset=''
for n,a,b,c in [('x',"{18'd0,(sw-16'd1),16'd0}",'{{1{product_cx[48]}},product_cx}','{{1{product_sy[48]}},product_sy}'),
                ('y',"{18'd0,(sh-16'd1),16'd0}",'{{1{product_sx[48]}},product_sx}','{{1{product_cy[48]}},product_cy}'),
                ('n',"50'd0","{1'b0,product_cc}","{1'b0,product_ss}")]:
 text+=f'''wire [49:0] cfg_{n}_a={a},cfg_{n}_b={b},cfg_{n}_c={c};
wire [49:0] cfg_{n}_s=cfg_{n}_a ^ cfg_{n}_b ^ cfg_{n}_c;
wire [49:0] cfg_{n}_v=((cfg_{n}_a & cfg_{n}_b)|(cfg_{n}_a & cfg_{n}_c)|(cfg_{n}_b & cfg_{n}_c))<<1;
(* keep=1 *) reg [49:0] cfg_{n}_bytes;
(* keep=1 *) reg [6:0] cfg_{n}_g,cfg_{n}_p;
wire [7:0] cfg_{n}_carry;wire [49:0] cfg_{n}_result;
assign cfg_{n}_carry[0]=1'b0;
'''
 reset+=f'cfg_{n}_bytes<=0;cfg_{n}_g<=0;cfg_{n}_p<=0;\n'
 for i in range(7):
  lo=i*8;hi=min(lo+7,49);w=hi-lo+1
  text+=f"wire [{w}:0] cfg_{n}_add{i}={{1'b0,cfg_{n}_s[{hi}:{lo}]}}+{{1'b0,cfg_{n}_v[{hi}:{lo}]}};\n"
  carries=[f'cfg_{n}_g[{i}]']
  for j in range(i-1,-1,-1):carries.append('('+'&'.join([f'cfg_{n}_p[{k}]' for k in range(i,j,-1)]+[f'cfg_{n}_g[{j}]'])+')')
  text+=f'assign cfg_{n}_carry[{i+1}]='+'|'.join(carries)+';\n'
  text+=f'assign cfg_{n}_result[{hi}:{lo}]=cfg_{n}_bytes[{hi}:{lo}]+cfg_{n}_carry[{i}];\n'
  capture+=f'cfg_{n}_bytes[{hi}:{lo}]<=cfg_{n}_add{i}[{w-1}:0];cfg_{n}_g[{i}]<=cfg_{n}_add{i}[{w}];cfg_{n}_p[{i}]<=&cfg_{n}_add{i}[{w-1}:0];\n'
text+='''wire signed [49:0] tx=$signed(cfg_x_result)>>>1,ty=$signed(cfg_y_result)>>>1;
wire angle_bad=cfg_n_result<50'd4294836224 || cfg_n_result>50'd4295098368 ||
 tx < -50'sd2147483648 || tx>50'sd2147483647 || ty < -50'sd2147483648 || ty>50'sd2147483647;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;sw<=0;sh<=0;dw<=0;dh<=0;filter_mode<=0;cosine<=0;sine<=0;
  offset_x<=0;offset_y<=0;rsp_tag<=0;rsp_error<=0;
'''+reset+''' end else if(clk_en)begin
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
'''+capture+'''    state<=COMMIT;
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
'''+core+'''
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
'''
out=HERE/'geo_mapping_optimized/rotate_config_serial_v7/cip_image_rotate_angle_frame.v'
out.parent.mkdir(exist_ok=True);out.write_text(text)
print(out)
