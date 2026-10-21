// Development draft, unverified. Blends two already warped, co-registered canvases.
// Lens calibration, feature extraction/matching, homography and warping are external.
module img_mf_stitch_registered #(
    parameter TAG_WIDTH = 16, parameter FRAME_WIDTH = 16
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire s_valid, output wire s_ready, input wire [23:0] s_data,
    input wire s_present, input wire s_sof, input wire s_eol,
    input wire [TAG_WIDTH-1:0] s_tag, input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid, output wire aux_ready, input wire [23:0] aux_data,
    input wire aux_present, input wire [8:0] aux_seam_weight,
    input wire aux_sof, input wire aux_eol,
    input wire [TAG_WIDTH-1:0] aux_tag, input wire [FRAME_WIDTH-1:0] aux_frameid,
    input wire cfg_we, input wire cfg_commit, input wire cfg_external_registration,
    input wire [23:0] cfg_background,
    output wire cfg_ready, output reg cfg_pending,
    output reg m_valid, input wire m_ready, output reg [23:0] m_data,
    output reg m_sof, output reg m_eol,
    output reg [TAG_WIDTH-1:0] m_tag, output reg [FRAME_WIDTH-1:0] m_frameid,
    output reg [7:0] m_error, output wire [7:0] error_code
);
    wire p_valid, p_ready, p_sof, p_eol;
    wire [33:0] p_data, p_aux;
    wire [7:0] p_error, pair_sticky;
    wire [TAG_WIDTH-1:0] p_tag;
    wire [FRAME_WIDTH-1:0] p_frameid;
    reg active_registered, shadow_registered;
    reg [23:0] active_background, shadow_background;
    reg [7:0] local_error;
    wire new_cfg = cfg_pending && p_sof && p_error == 0;
    wire registered_now = new_cfg ? shadow_registered : active_registered;
    wire [23:0] background_now = new_cfg ? shadow_background : active_background;
    wire [8:0] weight = p_aux[32:24];
    wire [7:0] beat_error = p_error | (!registered_now ? 8'h20 : 8'h00) |
        ((p_data[33] && p_aux[33] && weight > 9'd256) ? 8'h10 : 8'h00);
    wire room = !m_valid || m_ready;
    assign p_ready = room;
    assign cfg_ready = rst_n && clk_en && !cfg_pending;
    assign error_code = pair_sticky | local_error;
    img_mf_pair_join #(.DATA_WIDTH(34), .TAG_WIDTH(TAG_WIDTH), .FRAME_WIDTH(FRAME_WIDTH)) join_i (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_valid(s_valid), .s_ready(s_ready), .s_data({s_present,9'd0,s_data}), .s_sof(s_sof), .s_eol(s_eol), .s_tag(s_tag), .s_frameid(s_frameid),
        .aux_valid(aux_valid), .aux_ready(aux_ready), .aux_data({aux_present,aux_seam_weight,aux_data}), .aux_sof(aux_sof), .aux_eol(aux_eol), .aux_tag(aux_tag), .aux_frameid(aux_frameid),
        .m_valid(p_valid), .m_ready(p_ready), .m_data(p_data), .m_aux_data(p_aux), .m_sof(p_sof), .m_eol(p_eol), .m_tag(p_tag), .m_frameid(p_frameid), .m_error(p_error), .error_code(pair_sticky)
    );
    function [7:0] seam_blend;
        input [7:0] a, b;
        input [8:0] w;
        reg [17:0] total;
        begin
            total = a * (9'd256-w) + b * w + 18'd128;
            seam_blend = total[15:8];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_registered <= 0; shadow_registered <= 0;
            active_background <= 0; shadow_background <= 0;
            cfg_pending <= 0; local_error <= 0;
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0;
            m_tag <= 0; m_frameid <= 0; m_error <= 0;
        end else if (clk_en) begin
            if (cfg_ready) begin
                if (cfg_we) begin
                    shadow_registered <= cfg_external_registration;
                    shadow_background <= cfg_background;
                end
                if (cfg_commit) cfg_pending <= 1'b1;
            end
            if (room) begin
                m_valid <= p_valid;
                if (p_valid) begin
                    if (beat_error != 0) m_data <= 24'd0;
                    else if (p_data[33] && p_aux[33]) m_data <= {
                        seam_blend(p_data[23:16],p_aux[23:16],weight),
                        seam_blend(p_data[15:8],p_aux[15:8],weight),
                        seam_blend(p_data[7:0],p_aux[7:0],weight)};
                    else if (p_data[33]) m_data <= p_data[23:0];
                    else if (p_aux[33]) m_data <= p_aux[23:0];
                    else m_data <= background_now;
                    m_sof <= p_sof; m_eol <= p_eol; m_tag <= p_tag; m_frameid <= p_frameid;
                    m_error <= beat_error; local_error <= local_error | beat_error;
                    if (new_cfg) begin
                        active_registered <= shadow_registered;
                        active_background <= shadow_background; cfg_pending <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
