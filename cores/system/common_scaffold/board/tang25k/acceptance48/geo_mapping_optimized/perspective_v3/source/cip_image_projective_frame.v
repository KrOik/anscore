// Functional dynamic inverse-matrix transform; shared CE.
module cip_image_projective_frame #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64, parameter PIXEL_W=8, parameter PERSPECTIVE=0)(
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
localparam IDLE=0,START=1,RUN=2,RESPONSE=3,LOAD=4,COMMIT=5;
localparam LANES=DATA_W/(PIXEL_W>0?PIXEL_W:1);
localparam SUPPORTED=PIXEL_W>=1 && PIXEL_W<=16 && DATA_W>=PIXEL_W && DATA_W<=32 &&
 DATA_W==PIXEL_W*LANES && MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 &&
 (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
reg [2:0] state;
reg signed [31:0] active[0:8],staging[0:8];
reg [8:0] seen;reg [3:0] received;reg bad_load;integer k;
wire coefficient_bad=coeff_addr>=9 || (coeff_addr<9 && seen[coeff_addr]);
wire load_bad=!SUPPORTED || cfg_src_width!=0 || cfg_src_height!=0 || cfg_dst_width!=0 || cfg_dst_height!=0 || cfg_param0!=0 || cfg_param1!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
reg [15:0] sw,sh,dw,dh;
reg filter_mode;
wire core_ready,core_rv,core_sr,core_mv,core_ms,core_me;
wire [3:0] core_error;
wire [DATA_W-1:0] core_data;
wire bad_config=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 ||
 cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT || cfg_dst_width==0 || cfg_dst_height==0 ||
 cfg_param0!=0 || cfg_param1!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && core_mv;
assign m_data=core_data;
assign m_sof=m_valid && core_ms;
assign m_eol=m_valid && core_me;
assign coeff_ready=rst_n && state==LOAD;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;sw<=0;sh<=0;dw<=0;dh<=0;filter_mode<=0;rsp_tag<=0;rsp_error<=0;seen<=0;received<=0;bad_load<=0;
 for(k=0;k<9;k=k+1)begin active[k]<= (k==0 || k==4 || k==8)?32'sd65536:0;staging[k]<=0;end end
 else if(clk_en)begin
  case(state)
   IDLE:if(cmd_valid && cmd_ready)begin
    rsp_tag<=cmd_tag;rsp_error<=0;
    if(cfg_mode==2)begin
     seen<=0;received<=0;bad_load<=0;
     if(load_bad)begin state<=RESPONSE;rsp_error<=2;end else state<=LOAD;
    end
    else if(cfg_mode>2)begin state<=RESPONSE;rsp_error<=1;end
    else if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
    else begin state<=START;sw<=cfg_src_width;sh<=cfg_src_height;dw<=cfg_dst_width;dh<=cfg_dst_height;filter_mode<=cfg_mode[0];end
   end
   LOAD:if(coeff_valid && coeff_ready)begin
    received<=received+1;
    if(coefficient_bad)bad_load<=1;
    if(coeff_addr<9)begin staging[coeff_addr]<=coeff_data;seen[coeff_addr]<=1;end
    if(received==8)begin
     if(bad_load || coefficient_bad || ((seen | (9'b1<<coeff_addr))!=9'h1ff))begin state<=RESPONSE;rsp_error<=2;end
     else state<=COMMIT;
    end
   end
   COMMIT:begin
    if(!PERSPECTIVE && (staging[6]!=0 || staging[7]!=0 || staging[8]!=65536))rsp_error<=2;
    else for(k=0;k<9;k=k+1)active[k]<=staging[k];
    state<=RESPONSE;
   end
   START:if(core_ready)state<=RUN;
   RUN:if(core_rv)begin
    rsp_error<=core_error==0?2'd0:((core_error==1 || core_error==2 || core_error==4)?2'd2:2'd3);
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
 .cfg_mode(PERSPECTIVE?4'd8:4'd7),.cfg_filter({1'b0,filter_mode}),.cfg_src_width(sw),.cfg_src_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_h00(active[0]),.cfg_h01(active[1]),.cfg_h02(active[2]),.cfg_h10(active[3]),.cfg_h11(active[4]),.cfg_h12(active[5]),
 .cfg_h20(active[6]),.cfg_h21(active[7]),.cfg_h22(active[8]),.busy(),
 .rsp_valid(core_rv),.rsp_ready(state==RUN),.rsp_tag(),.rsp_error(core_error),.rsp_pixels(),
 .s_valid(s_valid && state==RUN),.s_ready(core_sr),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(core_mv),.m_ready(m_ready && state==RUN),.m_data(core_data),.m_error(),.m_sof(core_ms),.m_eol(core_me),.m_eof());
end else begin:unsupported
 assign core_ready=0;assign core_rv=0;assign core_sr=0;assign core_mv=0;assign core_ms=0;assign core_me=0;assign core_data=0;assign core_error=0;
end endgenerate
endmodule
