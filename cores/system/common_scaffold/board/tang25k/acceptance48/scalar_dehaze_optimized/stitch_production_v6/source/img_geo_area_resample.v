// Exact pixel-area box resampling (antialiased reduction / SSAA resolve).
// Integrates piecewise-constant input over each destination footprint using
// integer overlap areas, not quantized point sampling.
module img_geo_area_resample #(
 parameter PIXEL_W=8,LANES=3,TAG_W=8,MAX_WIDTH=64,MAX_HEIGHT=64
)(
 input wire clk,rst_n,clk_en,
 input wire cfg_valid,output wire cfg_ready,input wire [TAG_W-1:0] cfg_tag,
 input wire [15:0] cfg_src_width,cfg_src_height,cfg_dst_width,cfg_dst_height,
 output wire busy,output reg rsp_valid,input wire rsp_ready,
 output reg [TAG_W-1:0] rsp_tag,output reg [3:0] rsp_error,
 input wire s_valid,output wire s_ready,input wire [PIXEL_W*LANES-1:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output reg [PIXEL_W*LANES-1:0] m_data,
 output wire m_sof,m_eol,m_eof
);
localparam IDLE=0,CAPTURE=1,SETUP=2,READ_PIXEL=3,ACCUMULATE=4,NORMALIZE=5,SEND=6,DIV_START=7,DIV_WAIT=8,OVERLAP=9,WEIGHT=10,MULTIPLY=11;
localparam DEPTH=MAX_WIDTH*MAX_HEIGHT,AW=(DEPTH<2)?1:$clog2(DEPTH);
// Configuration rejects dimensions above MAX_WIDTH/MAX_HEIGHT before storing
// them. Derive arithmetic widths from those actual bounds: coordinate products
// need at most twice the dimension width, overlap weight at most XW+YW, and the
// weighted pixel sum at most PIXEL_W+XW+YW.
localparam integer XW=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH+1);
localparam integer YW=(MAX_HEIGHT<2)?1:$clog2(MAX_HEIGHT+1);
localparam integer XEDGE_W=2*XW, YEDGE_W=2*YW;
localparam integer AREA_W=XW+YW;
localparam integer ACC_W=PIXEL_W+AREA_W;
localparam integer CAP_W=(DEPTH<2)?1:$clog2(DEPTH+1);
reg [3:0] state;
reg [PIXEL_W*LANES-1:0] frame_ram [0:DEPTH-1];
reg [PIXEL_W*LANES-1:0] read_data;
reg [XW-1:0] sw,dw,ix,ox,sx,last_sx,first_sx;
reg [YW-1:0] sh,dh,iy,oy,sy,last_sy;
reg [CAP_W-1:0] capture_addr;
reg [3:0] frame_error;
reg [XEDGE_W-1:0] left_x,right_x;
reg [YEDGE_W-1:0] left_y,right_y;
reg [AREA_W-1:0] denominator;
reg [ACC_W-1:0] accum [0:LANES-1];
reg [XEDGE_W-1:0] cell_lx,cell_rx;
reg [YEDGE_W-1:0] cell_ly,cell_ry;
reg [XW-1:0] overlap_x;
reg [YW-1:0] overlap_y;
reg [AREA_W-1:0] weight;
integer lane;
wire [AW-1:0] read_addr=AW'(sy)*AW'(sw)+AW'(sx);
assign cfg_ready=rst_n && state==IDLE && !rsp_valid;
assign busy=state!=IDLE;
assign s_ready=rst_n && state==CAPTURE;
assign m_valid=rst_n && state==SEND;
assign m_sof=ox==0 && oy==0;
assign m_eol=ox==dw-1'b1;
assign m_eof=m_eol && oy==dh-1'b1;
localparam DIV_W=(ACC_W>XEDGE_W?(ACC_W>YEDGE_W?ACC_W:YEDGE_W):(XEDGE_W>YEDGE_W?XEDGE_W:YEDGE_W));
reg [DIV_W-1:0] div_n,div_d;
wire [DIV_W-1:0] div_q;wire div_done,div_error;
reg [2:0] div_phase;
integer normalize_lane;
reg [ACC_W-1:0] products[0:LANES-1];
geo_serial_divider #(.W(DIV_W)) divider(.clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start(state==DIV_START),.numerator(div_n),.denominator(div_d),.done(div_done),.error(div_error),.quotient(div_q));
always @(posedge clk) if(rst_n && clk_en) begin
 if(s_valid && s_ready) frame_ram[capture_addr[AW-1:0]]<=s_data;
 if(state==READ_PIXEL) read_data<=frame_ram[read_addr[AW-1:0]];
end
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  state<=IDLE;div_n<=0;div_d<=1;div_phase<=0;normalize_lane<=0;sw<=0;sh<=0;dw<=0;dh<=0;ix<=0;iy<=0;ox<=0;oy<=0;sx<=0;sy<=0;
  last_sx<=0;last_sy<=0;first_sx<=0;capture_addr<=0;frame_error<=0;
  left_x<=0;right_x<=0;left_y<=0;right_y<=0;denominator<=1;
  rsp_valid<=0;rsp_tag<=0;rsp_error<=0;m_data<=0;
  for(lane=0;lane<LANES;lane=lane+1) accum[lane]<=0;
 end else if(clk_en) begin
  if(rsp_valid && rsp_ready) rsp_valid<=0;
  case(state)
   IDLE: if(cfg_valid && cfg_ready) begin
    rsp_tag<=cfg_tag;rsp_error<=0;
    if(PIXEL_W<1 || PIXEL_W>16 || LANES<1 || MAX_WIDTH<1 || MAX_HEIGHT<1 || cfg_src_width==0 || cfg_src_height==0 ||
       cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT || cfg_dst_width==0 || cfg_dst_height==0)
     begin rsp_valid<=1;rsp_error<=1;end
    else begin
     sw<=cfg_src_width;sh<=cfg_src_height;dw<=cfg_dst_width;dh<=cfg_dst_height;
     denominator<=AREA_W'(cfg_src_width)*AREA_W'(cfg_src_height);
     ix<=0;iy<=0;ox<=0;oy<=0;capture_addr<=0;frame_error<=0;state<=CAPTURE;
    end
   end
   CAPTURE: if(s_valid && s_ready) begin
    if(s_sof!=(ix==0 && iy==0) || s_eol!=(ix==sw-1'b1)) frame_error<=2;
    capture_addr<=capture_addr+1'b1;
    if(ix==sw-1'b1) begin ix<=0;iy<=iy+1'b1;end else ix<=ix+1'b1;
    if(ix==sw-1'b1 && iy==sh-1'b1) begin
     if(frame_error!=0 || s_sof!=(ix==0 && iy==0) || s_eol!=(ix==sw-1'b1))
      begin state<=IDLE;rsp_valid<=1;rsp_error<=2;end
     else state<=SETUP;
    end
   end
   SETUP: begin
    left_x<=XEDGE_W'(ox)*XEDGE_W'(sw);
    right_x<=(XEDGE_W'(ox)+1'b1)*XEDGE_W'(sw);
    left_y<=YEDGE_W'(oy)*YEDGE_W'(sh);
    right_y<=(YEDGE_W'(oy)+1'b1)*YEDGE_W'(sh);
    div_n<=XEDGE_W'(ox)*XEDGE_W'(sw);div_d<=dw;div_phase<=0;normalize_lane<=0;
    for(lane=0;lane<LANES;lane=lane+1) accum[lane]<=0;
    state<=DIV_START;
   end
   DIV_START:state<=DIV_WAIT;
   DIV_WAIT:if(div_done)begin
    if(div_error)begin state<=IDLE;rsp_valid<=1;rsp_error<=1;end
    else case(div_phase)
     0:begin sx<=div_q;first_sx<=div_q;div_n<=right_x-1'b1;div_d<=dw;div_phase<=1;state<=DIV_START;end
     1:begin last_sx<=div_q;div_n<=left_y;div_d<=dh;div_phase<=2;state<=DIV_START;end
     2:begin sy<=div_q;div_n<=right_y-1'b1;div_d<=dh;div_phase<=3;state<=DIV_START;end
     3:begin last_sy<=div_q;state<=READ_PIXEL;end
     4:begin
      m_data[normalize_lane*PIXEL_W+:PIXEL_W]<=div_q;
      if(normalize_lane==LANES-1)state<=SEND;
      else begin normalize_lane<=normalize_lane+1;state<=NORMALIZE;end
     end
    endcase
   end
   READ_PIXEL:begin
    cell_lx<=XEDGE_W'(sx)*XEDGE_W'(dw);cell_rx<=(XEDGE_W'(sx)+1'b1)*XEDGE_W'(dw);
    cell_ly<=YEDGE_W'(sy)*YEDGE_W'(dh);cell_ry<=(YEDGE_W'(sy)+1'b1)*YEDGE_W'(dh);
    state<=OVERLAP;
   end
   OVERLAP:begin
    overlap_x<=(right_x<cell_rx?right_x:cell_rx)-(left_x>cell_lx?left_x:cell_lx);
    overlap_y<=(right_y<cell_ry?right_y:cell_ry)-(left_y>cell_ly?left_y:cell_ly);
    state<=WEIGHT;
   end
   WEIGHT:begin weight<=AREA_W'(overlap_x)*AREA_W'(overlap_y);state<=MULTIPLY;end
   MULTIPLY:begin
    for(lane=0;lane<LANES;lane=lane+1)products[lane]<=ACC_W'(read_data[lane*PIXEL_W+:PIXEL_W])*weight;
    state<=ACCUMULATE;
   end
   ACCUMULATE: begin
    for(lane=0;lane<LANES;lane=lane+1)
     accum[lane]<=accum[lane]+products[lane];
    if(sx==last_sx && sy==last_sy) state<=NORMALIZE;
    else begin
     if(sx==last_sx) begin sx<=first_sx;sy<=sy+1'b1;end else sx<=sx+1'b1;
     state<=READ_PIXEL;
    end
   end
   NORMALIZE:begin
    div_n<=accum[normalize_lane]+(denominator>>1);div_d<=denominator;div_phase<=4;state<=DIV_START;
   end
   SEND: if(m_ready) begin
    if(m_eof) begin state<=IDLE;rsp_valid<=1;rsp_error<=0;end
    else begin if(m_eol) begin ox<=0;oy<=oy+1'b1;end else ox<=ox+1'b1;state<=SETUP;end
   end
   default: begin state<=IDLE;rsp_valid<=1;rsp_error<=1;end
  endcase
 end
end
endmodule
