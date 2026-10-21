// Development draft. Raster crop and point decimation, without line/frame RAM.
// Decimation does NOT perform the antialias filtering required for general images.
// All handshakes are valid && ready && clk_en. Config accepts one source frame.
module img_geo_crop_decimate #(
    parameter DATA_W = 24
)(
    input wire clk, rst_n, clk_en,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [15:0] cfg_src_width, cfg_src_height,
    input wire [15:0] cfg_crop_x, cfg_crop_y,
    input wire [15:0] cfg_crop_width, cfg_crop_height,
    input wire [15:0] cfg_step_x, cfg_step_y,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    output wire busy,
    input wire s_valid,
    output wire s_ready,
    input wire [DATA_W-1:0] s_data,
    input wire s_sof, s_eol,
    output reg m_valid,
    input wire m_ready,
    output reg [DATA_W-1:0] m_data,
    output reg m_sof, m_eol
);
localparam [3:0] E_OK=0, E_CONFIG=1, E_FRAME=2;
reg active, source_done;
reg [15:0] src_w, src_h, crop_x, crop_y, crop_w, crop_h, step_x, step_y;
reg [15:0] x, y;
reg [3:0] frame_error;
wire [16:0] cfg_end_x = {1'b0,cfg_crop_x}+{1'b0,cfg_crop_width};
wire [16:0] cfg_end_y = {1'b0,cfg_crop_y}+{1'b0,cfg_crop_height};
wire [16:0] end_x = {1'b0,crop_x}+{1'b0,crop_w};
wire [16:0] end_y = {1'b0,crop_y}+{1'b0,crop_h};
wire inside_roi = x>=crop_x && {1'b0,x}<end_x && y>=crop_y && {1'b0,y}<end_y;
// Runtime remainder is a functional draft; optimize with phase counters later.
wire selected = inside_roi && step_x!=0 && step_y!=0 &&
                ((x-crop_x)%step_x)==0 && ((y-crop_y)%step_y)==0;
wire out_space = !m_valid || m_ready;
assign cfg_ready = rst_n && !active && !rsp_valid && !m_valid;
assign s_ready = rst_n && active && !source_done && (!selected || out_space);
assign busy = active;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        active<=0; source_done<=0; rsp_valid<=0; rsp_error<=0;
        src_w<=0; src_h<=0; crop_x<=0; crop_y<=0; crop_w<=0; crop_h<=0;
        step_x<=1; step_y<=1; x<=0; y<=0; frame_error<=0;
        m_valid<=0; m_data<=0; m_sof<=0; m_eol<=0;
    end else if (clk_en) begin
        if (rsp_valid && rsp_ready) rsp_valid<=0;
        if (m_valid && m_ready) m_valid<=0;
        if (cfg_valid && cfg_ready) begin
            rsp_error<=E_OK;
            if (cfg_src_width==0 || cfg_src_height==0 || cfg_crop_width==0 ||
                cfg_crop_height==0 || cfg_step_x==0 || cfg_step_y==0 ||
                cfg_end_x>{1'b0,cfg_src_width} || cfg_end_y>{1'b0,cfg_src_height}) begin
                rsp_valid<=1; rsp_error<=E_CONFIG;
            end else begin
                src_w<=cfg_src_width; src_h<=cfg_src_height;
                crop_x<=cfg_crop_x; crop_y<=cfg_crop_y;
                crop_w<=cfg_crop_width; crop_h<=cfg_crop_height;
                step_x<=cfg_step_x; step_y<=cfg_step_y;
                x<=0; y<=0; frame_error<=E_OK; active<=1; source_done<=0;
            end
        end
        if (s_valid && s_ready) begin
            if (s_sof != (x==0 && y==0) || s_eol != (x==src_w-1'b1))
                frame_error<=E_FRAME;
            if (selected) begin
                m_valid<=1; m_data<=s_data;
                m_sof<=(x==crop_x && y==crop_y);
                m_eol<=({1'b0,x}+{1'b0,step_x}>=end_x);
            end
            if (x==src_w-1'b1) begin
                x<=0;
                if (y==src_h-1'b1) source_done<=1;
                else y<=y+1'b1;
            end else x<=x+1'b1;
        end
        if (active && source_done && (!m_valid || m_ready)) begin
            active<=0; source_done<=0; rsp_valid<=1; rsp_error<=frame_error;
        end
    end
end
endmodule
