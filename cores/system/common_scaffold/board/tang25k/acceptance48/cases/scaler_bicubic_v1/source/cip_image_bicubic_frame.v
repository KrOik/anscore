// Catmull-Rom a=-0.5, asymmetric Q8 coordinates, clamped edges.
// Coefficients Q16 rounded toward -infinity; w3 closes exact unit sum.
module cip_image_bicubic_frame #(
 parameter DATA_W=24,TAG_W=8,MAX_WIDTH=64,MAX_HEIGHT=64,PIXEL_W=8
)(
 input wire clk,rst_n,clk_en,
 input wire cmd_valid,output wire cmd_ready,input wire [TAG_W-1:0] cmd_tag,
 input wire [15:0] cfg_width,cfg_height,cfg_dst_width,cfg_dst_height,
 output wire rsp_valid,input wire rsp_ready,output reg [TAG_W-1:0] rsp_tag,
 output reg [1:0] rsp_error,
 input wire [DATA_W-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [DATA_W-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready
);
localparam LANES=DATA_W/(PIXEL_W>0?PIXEL_W:1);
localparam SUPPORTED=PIXEL_W>=1 && PIXEL_W<=16 && DATA_W>=PIXEL_W && DATA_W<=32 && DATA_W==LANES*PIXEL_W && MAX_WIDTH>=1 && MAX_HEIGHT>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT<=65535 && 64'd1*MAX_WIDTH*MAX_HEIGHT<=1048576;
localparam DEPTH=SUPPORTED?MAX_WIDTH*MAX_HEIGHT:1;
localparam IDLE=0,LOAD=1,COORD=2,ADDRESS=3,READ=4,ACCUM=5,PACK=6,OUTPUT=7,RESPONSE=8;
reg [3:0] state;
reg [DATA_W-1:0] ram[0:DEPTH-1];
reg [DATA_W-1:0] rd;
reg [31:0] address,load_index;
reg [15:0] sw,sh,dw,dh,ix,iy,ox,oy;
reg [31:0] qx,qy;
reg [3:0] tap;
reg signed [31:0] wx[0:3],wy[0:3];
reg signed [63:0] sums[0:LANES-1];
reg signed [63:0] rounded;
integer lane,xx,yy;
function signed [31:0] weight;
 input [7:0] t;input integer k;
 reg signed [63:0] a,b,c,n0,n1,n2;
 begin
 a=t;b=a*a;c=b*a;
 n0=(-65536*a+512*b-c)>>>9;
 n1=65536+((-1280*b+3*c)>>>9);
 n2=(65536*a+1024*b-3*c)>>>9;
 case(k)0:weight=n0;1:weight=n1;2:weight=n2;default:weight=65536-n0-n1-n2;endcase
 end
endfunction
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==LOAD;
assign m_valid=rst_n && state==OUTPUT;
assign m_sof=m_valid && ox==0 && oy==0;
assign m_eol=m_valid && ox==dw-1;
assign m_last=m_valid && ox==dw-1 && oy==dh-1;
// Both accesses are clocked and gated; coefficient/frame RAM has no asynchronous read.
always @(posedge clk)if(clk_en)begin
 if(state==LOAD && s_valid && s_ready)ram[load_index]<=s_data;
 if(state==READ)rd<=ram[address];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
 state<=IDLE;rsp_tag<=0;rsp_error<=0;m_data<=0;sw<=0;sh<=0;dw<=0;dh<=0;ix<=0;iy<=0;ox<=0;oy<=0;load_index<=0;address<=0;qx<=0;qy<=0;tap<=0;
 for(lane=0;lane<LANES;lane=lane+1)sums[lane]<=0;
 for(lane=0;lane<4;lane=lane+1)begin wx[lane]<=0;wy[lane]<=0;end
 end else if(clk_en)case(state)
 IDLE:if(cmd_valid)begin
 rsp_tag<=cmd_tag;rsp_error<=0;
 if(!SUPPORTED || cfg_width==0 || cfg_height==0 || cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT || cfg_dst_width==0 || cfg_dst_height==0)begin rsp_error<=2;state<=RESPONSE;end
 else begin sw<=cfg_width;sh<=cfg_height;dw<=cfg_dst_width;dh<=cfg_dst_height;ix<=0;iy<=0;ox<=0;oy<=0;load_index<=0;state<=LOAD;end
 end
 LOAD:if(s_valid)begin
 if(s_sof!=(ix==0 && iy==0) || s_eol!=(ix==sw-1))begin rsp_error<=2;state<=RESPONSE;end
 else if(ix==sw-1)begin ix<=0;iy<=iy+1;if(iy==sh-1)state<=COORD;end
 else ix<=ix+1;
 load_index<=load_index+1;
 end
 COORD:begin
 // 64-bit numerator prevents overflow for 16-bit destination positions.
 qx<=(64'd256*ox*sw)/dw;qy<=(64'd256*oy*sh)/dh;
 for(lane=0;lane<LANES;lane=lane+1)sums[lane]<=0;
 tap<=0;state<=ADDRESS;
 end
 ADDRESS:begin
 for(lane=0;lane<4;lane=lane+1)begin wx[lane]<=weight(qx[7:0],lane);wy[lane]<=weight(qy[7:0],lane);end
 xx=$signed({1'b0,qx[31:8]})+$signed({1'b0,tap[1:0]})-1;
 yy=$signed({1'b0,qy[31:8]})+$signed({1'b0,tap[3:2]})-1;
 if(xx<0)xx=0;else if(xx>=sw)xx=sw-1;
 if(yy<0)yy=0;else if(yy>=sh)yy=sh-1;
 address<=yy*sw+xx;state<=READ;
 end
 READ:state<=ACCUM;
 ACCUM:begin
 for(lane=0;lane<LANES;lane=lane+1)sums[lane]<=sums[lane]+$signed({{(64-PIXEL_W){1'b0}},rd[lane*PIXEL_W+:PIXEL_W]})*$signed(wx[tap[1:0]])*$signed(wy[tap[3:2]]);
 if(tap==15)state<=PACK;else begin tap<=tap+1;state<=ADDRESS;end
 end
 PACK:begin
 for(lane=0;lane<LANES;lane=lane+1)begin
 rounded=(sums[lane]+64'sd2147483648)>>>32;
 if(rounded<0)m_data[lane*PIXEL_W+:PIXEL_W]<=0;
 else if(rounded>((64'd1<<PIXEL_W)-1))m_data[lane*PIXEL_W+:PIXEL_W]<={PIXEL_W{1'b1}};
 else m_data[lane*PIXEL_W+:PIXEL_W]<=rounded[PIXEL_W-1:0];
 end
 state<=OUTPUT;
 end
 OUTPUT:if(m_ready)begin
 if(ox==dw-1)begin ox<=0;if(oy==dh-1)state<=RESPONSE;else begin oy<=oy+1;state<=COORD;end end
 else begin ox<=ox+1;state<=COORD;end
 end
 RESPONSE:if(rsp_ready)state<=IDLE;
 default:begin state<=RESPONSE;rsp_error<=3;end
 endcase
end
endmodule
