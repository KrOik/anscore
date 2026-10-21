// Development draft, unverified. Full-raster OSD: auxiliary blank pixels must exist.
module img_mf_osd_overlay #(
    parameter TAG_WIDTH = 16, parameter FRAME_WIDTH = 16
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire s_valid, output wire s_ready, input wire [23:0] s_data,
    input wire s_sof, input wire s_eol,
    input wire [TAG_WIDTH-1:0] s_tag, input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid, output wire aux_ready, input wire [23:0] aux_data,
    input wire aux_sof, input wire aux_eol,
    input wire [TAG_WIDTH-1:0] aux_tag, input wire [FRAME_WIDTH-1:0] aux_frameid,
    input wire cfg_we, input wire cfg_commit, input wire cfg_enable,
    input wire [8:0] cfg_alpha, input wire cfg_key_enable, input wire [23:0] cfg_color_key,
    output wire cfg_ready, output reg cfg_pending, output reg cfg_error,
    output wire m_valid, input wire m_ready, output wire [23:0] m_data,
    output wire m_sof, output wire m_eol,
    output wire [TAG_WIDTH-1:0] m_tag, output wire [FRAME_WIDTH-1:0] m_frameid,
    output wire [7:0] m_error, output wire [7:0] error_code
);
    wire p_valid, p_ready, p_sof, p_eol;
    wire [23:0] p_data, p_aux;
    wire [TAG_WIDTH-1:0] p_tag;
    wire [FRAME_WIDTH-1:0] p_frameid;
    wire [7:0] p_error, pair_sticky;
    reg [8:0] active_alpha, shadow_alpha;
    reg active_enable, shadow_enable, active_key_enable, shadow_key_enable;
    reg [23:0] active_key, shadow_key;
    wire new_cfg = cfg_pending && p_sof && p_error == 0;
    wire [8:0] alpha_now = new_cfg ? shadow_alpha : active_alpha;
    wire enable_now = new_cfg ? shadow_enable : active_enable;
    wire key_enable_now = new_cfg ? shadow_key_enable : active_key_enable;
    wire [23:0] key_now = new_cfg ? shadow_key : active_key;
    wire use_overlay = enable_now && !(key_enable_now && p_aux == key_now);
    wire pipe_ready;
    assign p_ready = pipe_ready;
    assign cfg_ready = rst_n && clk_en && !cfg_pending;
    assign error_code = pair_sticky | (cfg_error ? 8'h08 : 8'h00);
    img_mf_pair_join #(.TAG_WIDTH(TAG_WIDTH), .FRAME_WIDTH(FRAME_WIDTH)) join_i (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data), .s_sof(s_sof), .s_eol(s_eol), .s_tag(s_tag), .s_frameid(s_frameid),
        .aux_valid(aux_valid), .aux_ready(aux_ready), .aux_data(aux_data), .aux_sof(aux_sof), .aux_eol(aux_eol), .aux_tag(aux_tag), .aux_frameid(aux_frameid),
        .m_valid(p_valid), .m_ready(p_ready), .m_data(p_data), .m_aux_data(p_aux), .m_sof(p_sof), .m_eol(p_eol), .m_tag(p_tag), .m_frameid(p_frameid), .m_error(p_error), .error_code(pair_sticky)
    );
    img_mf_rgb_blend_pipe #(.TAG_WIDTH(TAG_WIDTH),.FRAME_WIDTH(FRAME_WIDTH)) blend_i (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_valid(p_valid),.s_ready(pipe_ready),
        .s_base(p_data),.s_aux(p_aux),.s_weight(alpha_now),.s_use_blend(use_overlay),
        .s_sof(p_sof),.s_eol(p_eol),.s_tag(p_tag),.s_frameid(p_frameid),.s_error(p_error),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_sof(m_sof),.m_eol(m_eol),
        .m_tag(m_tag),.m_frameid(m_frameid),.m_error(m_error));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            active_alpha<=9'd256;shadow_alpha<=9'd256;
            active_enable<=0;shadow_enable<=0;active_key_enable<=0;shadow_key_enable<=0;
            active_key<=0;shadow_key<=0;cfg_pending<=0;cfg_error<=0;
        end else if(clk_en)begin
            if(cfg_ready)begin
                if(cfg_we && cfg_alpha<=9'd256)begin
                    shadow_alpha<=cfg_alpha;shadow_enable<=cfg_enable;
                    shadow_key_enable<=cfg_key_enable;shadow_key<=cfg_color_key;
                end
                if(cfg_we && cfg_alpha>9'd256)cfg_error<=1;
                if(cfg_commit)begin
                    if(!cfg_we || cfg_alpha<=9'd256)cfg_pending<=1;
                    else cfg_error<=1;
                end
            end
            if(p_valid && p_ready && new_cfg)begin
                active_alpha<=shadow_alpha;active_enable<=shadow_enable;
                active_key_enable<=shadow_key_enable;active_key<=shadow_key;cfg_pending<=0;
            end
        end
    end
endmodule
