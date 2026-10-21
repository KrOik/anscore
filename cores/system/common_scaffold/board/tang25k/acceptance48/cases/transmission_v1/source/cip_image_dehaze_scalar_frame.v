// Internal scalar DCP and spatial dark-channel frame engine.
module cip_image_dehaze_scalar_frame #(parameter KIND=0,DATA_W=24,TAG_W=8,MAX_WIDTH=32,MAX_HEIGHT=32,MAX_RADIUS=3)(
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
localparam IDLE=0,CAPTURE=1,REQ=2,READ=3,SCAN_REQ=4,SCAN_CAP=5,SEND=6,WAIT=7,OUT=8,RESPONSE=9;
localparam SUPPORTED=(KIND==1?DATA_W>=16:DATA_W>=24) && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=512 && MAX_HEIGHT>=1 && MAX_HEIGHT<=512 && MAX_RADIUS>=0 && MAX_RADIUS<=7;
localparam DEPTH=MAX_WIDTH*MAX_HEIGHT;
reg [3:0] state;reg [15:0] width,height,px,py;reg [31:0] count,total,index;
reg [2:0] radius;reg signed [5:0] dx,dy;integer nx,ny;reg [31:0] neighbor;
reg [15:0] omega,t0;reg [23:0] airlight;reg [7:0] airgray,darkmin;
(* ram_style="block",syn_ramstyle="block_ram" *) reg [23:0] rgb_mem[0:DEPTH-1];
(* ram_style="block",syn_ramstyle="block_ram" *) reg [15:0] t_mem[0:DEPTH-1];
reg [23:0] rgb_q;reg [15:0] t_q;reg [DATA_W-1:0] out;
wire need_aux=KIND==2;
wire bad=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT || cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0 ||
 (KIND==0?(cfg_param0>MAX_RADIUS || cfg_param1!=0):(cfg_param0[31:16]==0 || cfg_param0[31:16]>32768 || (KIND==1 && cfg_param0[15:0]>32768) || (KIND==2 && cfg_param0[15:0]!=0) || cfg_param1[31:24]!=0 || (KIND==1 && (cfg_param1[7:0]==0 || cfg_param1>255))));
wire fire=s_valid && s_ready;
assign cmd_ready=rst_n && state==IDLE;assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && clk_en && state==CAPTURE && (!need_aux || aux_valid);
assign aux_ready=rst_n && clk_en && state==CAPTURE && need_aux && s_valid;
assign m_valid=rst_n && state==OUT;assign m_data=out;assign m_sof=m_valid && index==0;assign m_eol=m_valid && px==width-1;
assign coeff_ready=0;assign mem_req_valid=0;assign mem_req_write=0;assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
wire [7:0] min_rgb=(rgb_q[23:16]<rgb_q[15:8])?((rgb_q[23:16]<rgb_q[7:0])?rgb_q[23:16]:rgb_q[7:0]):((rgb_q[15:8]<rgb_q[7:0])?rgb_q[15:8]:rgb_q[7:0]);
wire scalar_sr,scalar_mv;wire [15:0] trans_data;wire [23:0] restore_data;
always @*begin
 nx=$signed({1'b0,px})+$signed(dx);ny=$signed({1'b0,py})+$signed(dy);
 if(nx<0)nx=0;else if(nx>=width)nx=width-1;
 if(ny<0)ny=0;else if(ny>=height)ny=height-1;
 neighbor=ny*width+nx;
end
always @(posedge clk)if(clk_en)begin
 if(state==CAPTURE && fire)begin rgb_mem[count]<=s_data;t_mem[count]<=(aux_data>32768)?16'd32768:aux_data;end
 if(state==REQ)begin rgb_q<=rgb_mem[index];t_q<=t_mem[index];end
 if(state==SCAN_REQ)rgb_q<=rgb_mem[neighbor];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;width<=0;height<=0;px<=0;py<=0;count<=0;total<=0;index<=0;radius<=0;dx<=0;dy<=0;omega<=0;t0<=1;airlight<=0;airgray<=1;darkmin<=255;out<=0;rsp_tag<=0;rsp_error<=0;end
 else if(clk_en)case(state)
 IDLE:if(cmd_valid)begin rsp_tag<=cmd_tag;rsp_error<=0;
 if(cfg_mode!=0)begin state<=RESPONSE;rsp_error<=1;end
 else if(bad)begin state<=RESPONSE;rsp_error<=2;end
 else begin state<=CAPTURE;width<=cfg_src_width;height<=cfg_src_height;total<=32'(cfg_src_width)*cfg_src_height;count<=0;index<=0;px<=0;py<=0;radius<=cfg_param0[2:0];omega<=cfg_param0[15:0];t0<=cfg_param0[31:16];airlight<=cfg_param1[23:0];airgray<=cfg_param1[7:0];end end
 CAPTURE:if(fire)begin
 if(s_sof!=(count==0) || s_eol!=(px==width-1) || (s_data>>(KIND==1?8:24))!=0 || (need_aux && (aux_sof!=s_sof || aux_eol!=s_eol || aux_data>32768)))rsp_error<=2;
 count<=count+1;
 if(count==total-1)begin state<=REQ;px<=0;py<=0;end
 else if(px==width-1)begin px<=0;py<=py+1;end else px<=px+1;
 end
 REQ:state<=READ;
 READ:if(KIND==0)begin dx<=-$signed({1'b0,radius});dy<=-$signed({1'b0,radius});darkmin<=255;state<=SCAN_REQ;end else state<=SEND;
 SCAN_REQ:state<=SCAN_CAP;
 SCAN_CAP:begin
 if(min_rgb<darkmin)darkmin<=min_rgb;
 if(dx==$signed({1'b0,radius}) && dy==$signed({1'b0,radius}))begin out<=min_rgb<darkmin?min_rgb:darkmin;state<=OUT;end
 else begin if(dx==$signed({1'b0,radius}))begin dx<=-$signed({1'b0,radius});dy<=dy+1;end else dx<=dx+1;state<=SCAN_REQ;end
 end
 SEND:if(scalar_sr)state<=WAIT;
 WAIT:if(scalar_mv)begin out<=KIND==1?trans_data:restore_data;state<=OUT;end
 OUT:if(m_ready)begin
 if(index==total-1)state<=RESPONSE;
 else begin index<=index+1;if(px==width-1)begin px<=0;py<=py+1;end else px<=px+1;state<=REQ;end
 end
 RESPONSE:if(rsp_ready)state<=IDLE;
 default:begin state<=RESPONSE;rsp_error<=3;end
 endcase
end
generate if(KIND==1)begin
 img_dh_transmission core(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_dark(rgb_q[7:0]),.s_airlight_gray(airgray),.s_rgb(24'd0),.s_airlight_rgb(airlight),.s_omega(omega),.s_t0(t0),.s_valid(state==SEND),.s_sof(1'b0),.s_eol(1'b0),.s_ready(scalar_sr),.m_t(trans_data),.m_t0(),.m_rgb(),.m_airlight_rgb(),.m_valid(scalar_mv),.m_sof(),.m_eol(),.m_ready(state==WAIT),.unsupported(),.error());
 assign restore_data=0;
end else if(KIND==2)begin
 img_dh_restore core(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_rgb(rgb_q),.s_airlight_rgb(airlight),.s_t(t_q),.s_t0(t0),.s_valid(state==SEND),.s_sof(1'b0),.s_eol(1'b0),.s_ready(scalar_sr),.m_data(restore_data),.m_valid(scalar_mv),.m_sof(),.m_eol(),.m_ready(state==WAIT),.unsupported(),.error());
 assign trans_data=0;
end else begin assign scalar_sr=0;assign scalar_mv=0;assign trans_data=0;assign restore_data=0;end endgenerate
endmodule
