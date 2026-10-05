// Sobel/Scharr signed gradients; exact iterative floor sqrt or L1 magnitude.
module gradient_stream #(parameter BITS=8,WIDTH=32,HEIGHT=24,PAD_MODE=0)(
 input wire clk,rst_n,input wire [BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 output reg [3*(BITS+5)+4:0] m_tdata,output reg m_tvalid,m_tuser,m_tlast,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,input wire cfg_scharr,cfg_l1,
 input wire [BITS+4:0] cfg_threshold,input wire [1:0] cfg_reserved,
 output reg cfg_done,cfg_error,output wire marker_error,output reg busy
);
 localparam G=BITS+5,CW=$clog2(WIDTH*HEIGHT+1);
 localparam IDLE=0,SQUARE=1,ROOT=2;
 reg [1:0] state;
 reg scharr,l1;reg [G-1:0] threshold;
 reg [CW-1:0] ins,outs;
 wire [9*BITS-1:0] wd;wire wv,wu,wl,wr;
 wire ready_window=state==IDLE && (!m_tvalid || m_tready);
 assign cfg_ready=rst_n && !busy;
 wire allow=rst_n && ins<WIDTH*HEIGHT && !(cfg_valid&&cfg_ready);
 assign s_tready=allow&&wr;
 stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(3),.PAD_MODE(PAD_MODE)) win(
 clk,rst_n,s_tdata,s_tvalid&&allow,s_tuser,s_tlast,wr,wd,wv,wu,wl,ready_window,marker_error);
 wire signed [G-1:0] p[0:8];genvar i;
 generate for(i=0;i<9;i=i+1)begin: px
   assign p[i]=$signed({{(G-BITS){1'b0}},wd[i*BITS+:BITS]});
 end endgenerate
 wire signed [G-1:0] dx0=p[2]-p[0],dx1=p[5]-p[3],dx2=p[8]-p[6];
 wire signed [G-1:0] dy0=p[6]-p[0],dy1=p[7]-p[1],dy2=p[8]-p[2];
 wire signed [G-1:0] gx_new=scharr?((dx0<<<1)+dx0+(dx1<<<3)+(dx1<<<1)+(dx2<<<1)+dx2):(dx0+(dx1<<<1)+dx2);
 wire signed [G-1:0] gy_new=scharr?((dy0<<<1)+dy0+(dy1<<<3)+(dy1<<<1)+(dy2<<<1)+dy2):(dy0+(dy1<<<1)+dy2);
 reg signed [G-1:0] gx,gy;
 wire [G-1:0] ax=gx<0?-gx:gx,ay=gy<0?-gy:gy;
 wire [2*G-1:0] sx=gx*gx,sy=gy*gy;
 reg [2*G-1:0] radicand;
 reg [G+1:0] remainder;
 reg [G-1:0] root;
 reg [$clog2(G)-1:0] step;
 wire [G+1:0] shifted={remainder[G-1:0],radicand[2*G-1:2*G-2]};
 wire [G+1:0] trial={root,2'b01};
 wire [G-1:0] next_root={root[G-2:0],(shifted>=trial)};
 wire [G+1:0] next_rem=(shifted>=trial)?shifted-trial:shifted;
 wire [G+7:0] ax_w=ax,ay_w=ay;
 wire [G+7:0] ax53=(ax_w<<5)+(ax_w<<4)+(ax_w<<2)+ax_w;
 wire [G+7:0] ay53=(ay_w<<5)+(ay_w<<4)+(ay_w<<2)+ay_w;
 wire [1:0] quadrant_angle=((ay_w<<7)<ax53)?0:(((ax_w<<7)<ay53)?2:1);
 reg [2:0] angle;
 always @* begin
   if(ax==0 && ay==0)angle=0;
   else if(gx>=0 && gy>=0)angle=quadrant_angle;
   else if(gx<0 && gy>=0)angle=4-quadrant_angle;
   else if(gx<0 && gy<0)angle=4+quadrant_angle;
   else angle=0-quadrant_angle;
 end
 wire angle_valid=(ax!=0)||(ay!=0);
 wire [G-1:0] l1_mag=ax+ay;
 always @(posedge clk)begin
   if(!rst_n)begin
     state<=IDLE;scharr<=0;l1<=0;threshold<=0;ins<=0;outs<=0;busy<=0;
     m_tvalid<=0;m_tuser<=0;m_tlast<=0;cfg_done<=0;cfg_error<=0;
     step<=0;root<=0;remainder<=0;radicand<=0;gx<=0;gy<=0;
   end else begin
     cfg_done<=0;cfg_error<=0;if(m_tready)m_tvalid<=0;
     if(cfg_valid&&cfg_ready)begin
       if(cfg_reserved!=0)cfg_error<=1;
       else begin scharr<=cfg_scharr;l1<=cfg_l1;threshold<=cfg_threshold;cfg_done<=1;end
     end
     if(s_tvalid&&s_tready)begin ins<=ins+1'b1;busy<=1;end
     if(wv&&ready_window)begin gx<=gx_new;gy<=gy_new;m_tuser<=wu;m_tlast<=wl;state<=SQUARE;end
     if(state==SQUARE)begin
       if(l1)begin m_tdata<={(l1_mag>=threshold),angle_valid,angle,l1_mag,gy,gx};m_tvalid<=1;state<=IDLE;end
       else begin radicand<=sx+sy;remainder<=0;root<=0;step<=0;state<=ROOT;end
     end
     if(state==ROOT)begin
       radicand<=radicand<<2;remainder<=next_rem;root<=next_root;
       if(step==G-1)begin m_tdata<={(next_root>=threshold),angle_valid,angle,next_root,gy,gx};m_tvalid<=1;state<=IDLE;end
       else step<=step+1'b1;
     end
     if(m_tvalid&&m_tready)begin
       if(outs==WIDTH*HEIGHT-1)begin ins<=0;outs<=0;busy<=0;end else outs<=outs+1'b1;
     end
   end
 end
 initial begin
   if((BITS!=8&&BITS!=10)||WIDTH<1||HEIGHT<1||(PAD_MODE!=0&&PAD_MODE!=1))$fatal(1,"unsupported gradient parameters");
 end
endmodule
