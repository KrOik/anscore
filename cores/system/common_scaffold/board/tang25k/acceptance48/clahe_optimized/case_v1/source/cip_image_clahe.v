// Functional bounded 8-bit scalar CLAHE frame adapter.
// mode=0; param0=absolute clip count (1..16777215).
// param1={tile_height[15:0],tile_width[15:0]}; even tiles must divide frame.
// <=256 tiles, clip*256>=tile area. Equal source/destination dimensions.
// Strict ascending iterative unit redistribution; direct-CDF LUT; Q8 tile-center
// bilinear interpolation with nearest-tile border extension, rounded once.
// Malformed framing consumes the complete frame then returns error2, no output.
// High transport bits are ignored numerically and reported as error2 at end.
// Memory/coefficient/auxiliary interfaces are inactive; bases/stride must zero.
// No synthesis/timing/board qualification or OpenCV bit-parity claim.
module cip_image_clahe #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64, parameter GRAY_BITS=8)(
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
localparam GRID_X_W=($clog2(MAX_WIDTH+1)>0)?$clog2(MAX_WIDTH+1):1;
function [8:0] grid_x;input [15:0] dimension,tile;integer divisor;reg [GRID_X_W:0] numerator;
begin numerator={1'b0,dimension[GRID_X_W-1:0]}+{1'b0,tile[GRID_X_W-1:0]}-1'b1;grid_x=0;
for(divisor=1;divisor<=MAX_WIDTH;divisor=divisor+1)if(tile==divisor)grid_x=numerator/divisor;
end endfunction
localparam GRID_Y_W=($clog2(MAX_HEIGHT+1)>0)?$clog2(MAX_HEIGHT+1):1;
function [8:0] grid_y;input [15:0] dimension,tile;integer divisor;reg [GRID_Y_W:0] numerator;
begin numerator={1'b0,dimension[GRID_Y_W-1:0]}+{1'b0,tile[GRID_Y_W-1:0]}-1'b1;grid_y=0;
for(divisor=1;divisor<=MAX_HEIGHT;divisor=divisor+1)if(tile==divisor)grid_y=numerator/divisor;
end endfunction
localparam IDLE=0,START=1,RUN=2,RESPONSE=3;
localparam SUPPORTED=DATA_W>=GRAY_BITS && DATA_W<=32 && GRAY_BITS==8 && MAX_WIDTH>=1 && MAX_WIDTH<=65535 &&
    MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 && (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
reg [1:0] state;
reg [15:0] width,height;
reg [31:0] low,high;
reg high_error;
wire cfg_ready,core_sr,core_mv,core_ms,core_me,core_rv;
wire [GRAY_BITS-1:0] core_data;
wire [7:0] core_error;
wire bad_config=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
 cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || cfg_param0==0 || cfg_param0>16777215 ||
 cfg_param1[15:0]==0 || cfg_param1[31:16]==0 || cfg_param1[15:0]>cfg_src_width || cfg_param1[31:16]>cfg_src_height ||
 (grid_x(cfg_src_width,cfg_param1[15:0])*grid_y(cfg_src_height,cfg_param1[31:16]))>256 ||
 (64'd256*cfg_param0 < 64'd1*cfg_param1[15:0]*cfg_param1[31:16]) ||
 cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && core_mv;
assign m_data=core_data;
assign m_sof=m_valid && core_ms;assign m_eol=m_valid && core_me;
assign coeff_ready=0;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin state<=IDLE;width<=0;height<=0;low<=0;high<=0;high_error<=0;rsp_tag<=0;rsp_error<=0;end
    else if(clk_en)begin
        if(s_valid && s_ready && (s_data >> GRAY_BITS)!=0)high_error<=1;
        case(state)
        IDLE:if(cmd_valid && cmd_ready)begin
            rsp_tag<=cmd_tag;rsp_error<=0;high_error<=0;
            if(cfg_mode!=0)begin state<=RESPONSE;rsp_error<=1;end
            else if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
            else begin state<=START;width<=cfg_src_width;height<=cfg_src_height;low<=cfg_param0;high<=cfg_param1;end
        end
        START:if(cfg_ready)state<=RUN;
        RUN:begin
            if(core_rv)begin
                rsp_error<=(core_error & 8'hfd)!=0?2'd3:((core_error!=0 || high_error)?2'd2:2'd0);
                state<=RESPONSE;
            end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:state<=IDLE;
        endcase
    end
end
generate if(SUPPORTED)begin:enabled
    cip_image_clahe_frame #(.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.TAG_WIDTH(8)) core(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start_valid(state==START),.start_ready(cfg_ready),.start_tag(8'd0),
 .cfg_width(width),.cfg_height(height),.cfg_tile_width(high[15:0]),.cfg_tile_height(high[31:16]),.start_clip_limit(low[23:0]),
 .done_valid(core_rv),.done_ready(state==RUN),.done_error_code(core_error),
 .s_gray(s_data[7:0]),.s_valid(s_valid && state==RUN),.s_sof(s_sof),.s_eol(s_eol),.s_ready(core_sr),
 .m_gray(core_data),.m_valid(core_mv),.m_sof(core_ms),.m_eol(core_me),.m_ready(m_ready && state==RUN));
end else begin:unsupported
    assign cfg_ready=0;assign core_sr=0;assign core_mv=0;assign core_ms=0;assign core_me=0;
    assign core_data=0;assign core_rv=0;assign core_error=0;
end endgenerate
endmodule
