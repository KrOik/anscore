// Bounded-frame geometric transform. Synchronous pixel RAM is shared by
// capture and replay, which never run concurrently. Native CE handshakes.
module img_geo_frame_buffered #(
 parameter PIXEL_W=8,LANES=3,TAG_W=8,MAX_WIDTH=64,MAX_HEIGHT=64,
 parameter [PIXEL_W*LANES-1:0] BORDER_DATA=0
)(
 input wire clk,rst_n,clk_en,
 input wire cfg_valid,output wire cfg_ready,input wire [TAG_W-1:0] cfg_tag,
 input wire [3:0] cfg_mode,input wire [1:0] cfg_filter,
 input wire [15:0] cfg_src_width,cfg_src_height,cfg_dst_width,cfg_dst_height,
 input wire signed [31:0] cfg_h00,cfg_h01,cfg_h02,cfg_h10,cfg_h11,cfg_h12,cfg_h20,cfg_h21,cfg_h22,
 output wire busy,output reg rsp_valid,input wire rsp_ready,
 output reg [TAG_W-1:0] rsp_tag,output reg [3:0] rsp_error,output reg [31:0] rsp_pixels,
 input wire s_valid,output wire s_ready,input wire [PIXEL_W*LANES-1:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output wire [PIXEL_W*LANES-1:0] m_data,
 output wire [3:0] m_error,output wire m_sof,m_eol,m_eof
);
localparam IDLE=0,CAP_LAUNCH=1,CAPTURE=2,MAP_LAUNCH=3,REPLAY=4;
localparam DEPTH=MAX_WIDTH*MAX_HEIGHT,AW=(DEPTH<2)?1:$clog2(DEPTH);
reg [2:0] state;
reg [3:0] mode;reg [1:0] filter_mode;
reg [15:0] sw,sh,dw,dh;
reg signed [31:0] h00,h01,h02,h10,h11,h12,h20,h21,h22;
reg [PIXEL_W*LANES-1:0] frame_ram [0:DEPTH-1];
wire wr_cfg_ready,wr_rsp_valid;wire [3:0] wr_rsp_error;
wire wr_req_valid,wr_req_ready,wr_rsp_ready;
wire [31:0] wr_req_addr;wire [PIXEL_W*LANES-1:0] wr_req_data;
wire rd_cfg_ready,rd_rsp_valid;wire [3:0] rd_rsp_error;wire [31:0] rd_rsp_pixels;
wire rd_req_valid,rd_req_ready,rd_rsp_ready;wire [31:0] rd_req_addr;
reg mem_valid,mem_error;reg [PIXEL_W*LANES-1:0] mem_data;
wire capture_phase=state==CAPTURE || state==CAP_LAUNCH;
wire mem_ready=capture_phase?wr_rsp_ready:rd_rsp_ready;
wire req_space=!mem_valid || mem_ready;
assign wr_req_ready=rst_n && capture_phase && req_space;
assign rd_req_ready=rst_n && !capture_phase && req_space;
assign cfg_ready=rst_n && state==IDLE && !rsp_valid;
assign busy=state!=IDLE;
img_geo_frame_writer #(.DATA_W(PIXEL_W*LANES),.ADDR_W(32)) capture (
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(state==CAP_LAUNCH),.cfg_ready(wr_cfg_ready),
 .cfg_width(sw),.cfg_height(sh),.cfg_stride({16'd0,sw}),.cfg_base_addr(32'd0),.busy(),
 .rsp_valid(wr_rsp_valid),.rsp_ready(state==CAPTURE),.rsp_error(wr_rsp_error),
 .s_valid(s_valid && state==CAPTURE),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .mem_req_valid(wr_req_valid),.mem_req_ready(wr_req_ready),.mem_req_write(),.mem_req_addr(wr_req_addr),.mem_req_data(wr_req_data),
 .mem_rsp_valid(mem_valid && capture_phase),.mem_rsp_ready(wr_rsp_ready),.mem_rsp_error(mem_error)
);
img_geo_frame_transform #(.PIXEL_W(PIXEL_W),.LANES(LANES),.ADDR_W(32),.BORDER_DATA(BORDER_DATA)) transform (
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(state==MAP_LAUNCH),.cfg_ready(rd_cfg_ready),
 .cfg_mode(mode),.cfg_filter(filter_mode),.cfg_src_width(sw),.cfg_src_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_stride({16'd0,sw}),.cfg_base_addr(32'd0),.cfg_h00(h00),.cfg_h01(h01),.cfg_h02(h02),
 .cfg_h10(h10),.cfg_h11(h11),.cfg_h12(h12),.cfg_h20(h20),.cfg_h21(h21),.cfg_h22(h22),.busy(),
 .rsp_valid(rd_rsp_valid),.rsp_ready(state==REPLAY),.rsp_error(rd_rsp_error),.rsp_pixels(rd_rsp_pixels),
 .mem_req_valid(rd_req_valid),.mem_req_ready(rd_req_ready),.mem_req_read(),.mem_req_addr(rd_req_addr),
 .mem_rsp_valid(mem_valid && !capture_phase),.mem_rsp_ready(rd_rsp_ready),.mem_rsp_data(mem_data),.mem_rsp_error(mem_error),
 .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_error(m_error),.m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof)
);
// RAM contents need no reset. Both memory operations are clocked.
always @(posedge clk) if(rst_n && clk_en) begin
 if(wr_req_valid && wr_req_ready && wr_req_addr<DEPTH) frame_ram[wr_req_addr[AW-1:0]]<=wr_req_data;
 if(rd_req_valid && rd_req_ready && rd_req_addr<DEPTH) mem_data<=frame_ram[rd_req_addr[AW-1:0]];
end
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  state<=IDLE;mode<=0;filter_mode<=0;sw<=0;sh<=0;dw<=0;dh<=0;
  h00<=0;h01<=0;h02<=0;h10<=0;h11<=0;h12<=0;h20<=0;h21<=0;h22<=0;
  rsp_valid<=0;rsp_tag<=0;rsp_error<=0;rsp_pixels<=0;mem_valid<=0;mem_error<=0;
 end else if(clk_en) begin
  if(rsp_valid && rsp_ready) rsp_valid<=0;
  if(mem_valid && mem_ready) mem_valid<=0;
  if(wr_req_valid && wr_req_ready) begin mem_valid<=1;mem_error<=wr_req_addr>=DEPTH;end
  if(rd_req_valid && rd_req_ready) begin mem_valid<=1;mem_error<=rd_req_addr>=DEPTH;end
  case(state)
   IDLE: if(cfg_valid && cfg_ready) begin
    rsp_tag<=cfg_tag;rsp_error<=0;rsp_pixels<=0;
    if(PIXEL_W<1 || PIXEL_W>16 || LANES<1 || MAX_WIDTH<1 || MAX_HEIGHT<1 ||
       cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
       cfg_dst_width==0 || cfg_dst_height==0) begin rsp_valid<=1;rsp_error<=1;end
    else if(cfg_mode>8 || cfg_filter>1) begin rsp_valid<=1;rsp_error<=3;end
    else if(((cfg_mode==0 || cfg_mode==3 || cfg_mode==5 || cfg_mode==6) &&
             (cfg_src_width!=cfg_dst_width || cfg_src_height!=cfg_dst_height)) ||
            ((cfg_mode==2 || cfg_mode==4) &&
             (cfg_src_width!=cfg_dst_height || cfg_src_height!=cfg_dst_width))) begin rsp_valid<=1;rsp_error<=1;end
    else begin
     sw<=cfg_src_width;sh<=cfg_src_height;dw<=cfg_dst_width;dh<=cfg_dst_height;
     mode<=cfg_mode;filter_mode<=cfg_filter;
     h00<=cfg_h00;h01<=cfg_h01;h02<=cfg_h02;h10<=cfg_h10;h11<=cfg_h11;h12<=cfg_h12;h20<=cfg_h20;h21<=cfg_h21;h22<=cfg_h22;
     state<=CAP_LAUNCH;
    end
   end
   CAP_LAUNCH: if(wr_cfg_ready) state<=CAPTURE;
   CAPTURE: if(wr_rsp_valid) begin
    if(wr_rsp_error!=0) begin state<=IDLE;rsp_valid<=1;rsp_error<=wr_rsp_error;end
    else state<=MAP_LAUNCH;
   end
   MAP_LAUNCH: if(rd_cfg_ready) state<=REPLAY;
   REPLAY: if(rd_rsp_valid) begin state<=IDLE;rsp_valid<=1;rsp_error<=rd_rsp_error;rsp_pixels<=rd_rsp_pixels;end
   default: begin state<=IDLE;rsp_valid<=1;rsp_error<=1;end
  endcase
 end
end
endmodule
