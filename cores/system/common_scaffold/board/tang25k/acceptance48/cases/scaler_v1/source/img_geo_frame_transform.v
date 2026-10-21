// Development draft. Frame-backed image transform composition.
// A command emits exactly dst_width*dst_height pixels then a held completion.
// Requires img_geo_raster_coords, img_geo_inverse_map, img_geo_frame_sampler.
// No capture RAM/DDR controller is instantiated; a stable external source frame
// must remain available from command acceptance until completion.
module img_geo_frame_transform #(
    parameter PIXEL_W=8,
    parameter LANES=3,
    parameter ADDR_W=32,
    parameter [PIXEL_W*LANES-1:0] BORDER_DATA=0
)(
    input wire clk, rst_n, clk_en,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [3:0] cfg_mode,
    input wire [1:0] cfg_filter,
    input wire [15:0] cfg_src_width, cfg_src_height, cfg_dst_width, cfg_dst_height,
    input wire [31:0] cfg_stride,
    input wire [ADDR_W-1:0] cfg_base_addr,
    input wire signed [31:0] cfg_h00, cfg_h01, cfg_h02,
    input wire signed [31:0] cfg_h10, cfg_h11, cfg_h12,
    input wire signed [31:0] cfg_h20, cfg_h21, cfg_h22,
    output wire busy,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    output reg [31:0] rsp_pixels,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire mem_req_read,
    output wire [ADDR_W-1:0] mem_req_addr,
    input wire mem_rsp_valid,
    output wire mem_rsp_ready,
    input wire [PIXEL_W*LANES-1:0] mem_rsp_data,
    input wire mem_rsp_error,
    output wire m_valid,
    input wire m_ready,
    output wire [PIXEL_W*LANES-1:0] m_data,
    output wire [3:0] m_error,
    output wire m_sof, m_eol, m_eof
);
reg active, launch;
reg [3:0] mode, first_error;
reg [1:0] filter_mode;
reg [15:0] src_width, src_height, dst_width, dst_height;
reg [31:0] stride, pixels;
reg [ADDR_W-1:0] base_addr;
reg signed [31:0] h00,h01,h02,h10,h11,h12,h20,h21,h22;
wire raster_cfg_ready, raster_valid, raster_ready;
wire [15:0] raster_x,raster_y;
wire raster_sof,raster_eol,raster_eof;
wire raster_rsp_valid;
wire [3:0] raster_rsp_error;
wire map_valid,map_ready,map_border,map_sof,map_eol,map_eof;
wire [23:0] map_x,map_y;
wire [3:0] map_error;
wire unsupported = cfg_mode>8 || cfg_filter>1;
wire same_shape = cfg_mode==0 || cfg_mode==3 || cfg_mode==5 || cfg_mode==6;
wire swap_shape = cfg_mode==2 || cfg_mode==4;
wire invalid_shape = (same_shape && (cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height)) ||
                     (swap_shape && (cfg_dst_width!=cfg_src_height || cfg_dst_height!=cfg_src_width));
wire invalid_size = cfg_src_width==0 || cfg_src_height==0 || cfg_dst_width==0 ||
                    cfg_dst_height==0 || cfg_stride<cfg_src_width;
assign busy=active;
assign cfg_ready=rst_n && !active && !rsp_valid;

img_geo_raster_coords raster (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .cfg_valid(launch),.cfg_ready(raster_cfg_ready),
    .cfg_width(dst_width),.cfg_height(dst_height),
    .rsp_valid(raster_rsp_valid),.rsp_ready(1'b1),.rsp_error(raster_rsp_error),
    .m_valid(raster_valid),.m_ready(raster_ready),.m_x(raster_x),.m_y(raster_y),
    .m_sof(raster_sof),.m_eol(raster_eol),.m_eof(raster_eof)
);
img_geo_inverse_map mapper (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_valid(raster_valid),.s_ready(raster_ready),.s_x(raster_x),.s_y(raster_y),
    .s_sof(raster_sof),.s_eol(raster_eol),.s_eof(raster_eof),.s_mode(mode),
    .s_src_width(src_width),.s_src_height(src_height),.s_dst_width(dst_width),.s_dst_height(dst_height),
    .s_h00(h00),.s_h01(h01),.s_h02(h02),.s_h10(h10),.s_h11(h11),.s_h12(h12),
    .s_h20(h20),.s_h21(h21),.s_h22(h22),
    .m_valid(map_valid),.m_ready(map_ready),.m_x_q8(map_x),.m_y_q8(map_y),
    .m_border(map_border),.m_error(map_error),.m_sof(map_sof),.m_eol(map_eol),.m_eof(map_eof)
);
img_geo_frame_sampler #(.PIXEL_W(PIXEL_W),.LANES(LANES),.ADDR_W(ADDR_W),.BORDER_DATA(BORDER_DATA)) sampler (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_valid(map_valid),.s_ready(map_ready),.s_x_q8(map_x),.s_y_q8(map_y),
    .s_border(map_border),.s_error(map_error),.s_sof(map_sof),.s_eol(map_eol),.s_eof(map_eof),
    .s_filter(filter_mode),.s_src_width(src_width),.s_src_height(src_height),
    .s_stride(stride),.s_base_addr(base_addr),
    .mem_req_valid(mem_req_valid),.mem_req_ready(mem_req_ready),
    .mem_req_read(mem_req_read),.mem_req_addr(mem_req_addr),
    .mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),
    .mem_rsp_data(mem_rsp_data),.mem_rsp_error(mem_rsp_error),
    .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_error(m_error),
    .m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        active<=0; launch<=0; mode<=0; filter_mode<=0;
        first_error<=0; rsp_valid<=0; rsp_error<=0; rsp_pixels<=0; pixels<=0;
        src_width<=0; src_height<=0; dst_width<=0; dst_height<=0; stride<=0; base_addr<=0;
        h00<=0; h01<=0; h02<=0; h10<=0; h11<=0; h12<=0; h20<=0; h21<=0; h22<=0;
    end else if (clk_en) begin
        if (rsp_valid && rsp_ready) rsp_valid<=0;
        if (launch && raster_cfg_ready) launch<=0;
        if (cfg_valid && cfg_ready) begin
            rsp_error<=0; rsp_pixels<=0; pixels<=0; first_error<=0;
            if (unsupported) begin rsp_valid<=1; rsp_error<=3; end
            else if (invalid_size || invalid_shape) begin rsp_valid<=1; rsp_error<=1; end
            else begin
                active<=1; launch<=1; mode<=cfg_mode; filter_mode<=cfg_filter;
                src_width<=cfg_src_width; src_height<=cfg_src_height;
                dst_width<=cfg_dst_width; dst_height<=cfg_dst_height;
                stride<=cfg_stride; base_addr<=cfg_base_addr;
                h00<=cfg_h00; h01<=cfg_h01; h02<=cfg_h02;
                h10<=cfg_h10; h11<=cfg_h11; h12<=cfg_h12;
                h20<=cfg_h20; h21<=cfg_h21; h22<=cfg_h22;
            end
        end
        if (m_valid && m_ready) begin
            pixels<=pixels+1'b1;
            if (first_error==0 && m_error!=0) first_error<=m_error;
            if (m_eof) begin
                active<=0; rsp_valid<=1;
                rsp_pixels<=pixels+1'b1;
                rsp_error<=first_error!=0 ? first_error : m_error;
            end
        end
    end
end
endmodule
