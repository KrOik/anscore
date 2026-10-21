// Development draft, unverified. Grayscale current-vs-previous-frame comparison.
// aux_frameid names the target CURRENT frame, not the historical source frame.
module img_mf_frame_absdiff #(
    parameter TAG_WIDTH = 16, parameter FRAME_WIDTH = 16
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire s_valid, output wire s_ready, input wire [7:0] s_data,
    input wire s_sof, input wire s_eol,
    input wire [TAG_WIDTH-1:0] s_tag, input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid, output wire aux_ready, input wire [7:0] aux_data,
    input wire aux_sof, input wire aux_eol,
    input wire [TAG_WIDTH-1:0] aux_tag, input wire [FRAME_WIDTH-1:0] aux_frameid,
    input wire cfg_we, input wire cfg_commit, input wire [7:0] cfg_threshold,
    output wire cfg_ready, output reg cfg_pending,
    output reg m_valid, input wire m_ready, output reg [7:0] m_data,
    output reg m_foreground, output reg m_sof, output reg m_eol,
    output reg [TAG_WIDTH-1:0] m_tag, output reg [FRAME_WIDTH-1:0] m_frameid,
    output reg [7:0] m_error, output wire [7:0] error_code
);
    wire p_valid, p_ready, p_sof, p_eol;
    wire [7:0] p_data, p_aux, p_error;
    wire [TAG_WIDTH-1:0] p_tag;
    wire [FRAME_WIDTH-1:0] p_frameid;
    reg [7:0] active_threshold, shadow_threshold;
    wire [7:0] threshold_now = (cfg_pending && p_sof && p_error == 0) ? shadow_threshold : active_threshold;
    wire [7:0] difference = (p_data >= p_aux) ? p_data-p_aux : p_aux-p_data;
    wire room = !m_valid || m_ready;
    assign p_ready = room;
    assign cfg_ready = rst_n && clk_en && !cfg_pending;
    img_mf_pair_join #(.DATA_WIDTH(8), .TAG_WIDTH(TAG_WIDTH), .FRAME_WIDTH(FRAME_WIDTH)) join_i (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data), .s_sof(s_sof), .s_eol(s_eol), .s_tag(s_tag), .s_frameid(s_frameid),
        .aux_valid(aux_valid), .aux_ready(aux_ready), .aux_data(aux_data), .aux_sof(aux_sof), .aux_eol(aux_eol), .aux_tag(aux_tag), .aux_frameid(aux_frameid),
        .m_valid(p_valid), .m_ready(p_ready), .m_data(p_data), .m_aux_data(p_aux), .m_sof(p_sof), .m_eol(p_eol), .m_tag(p_tag), .m_frameid(p_frameid), .m_error(p_error), .error_code(error_code)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_threshold <= 8'd16; shadow_threshold <= 8'd16; cfg_pending <= 1'b0;
            m_valid <= 0; m_data <= 0; m_foreground <= 0; m_sof <= 0; m_eol <= 0;
            m_tag <= 0; m_frameid <= 0; m_error <= 0;
        end else if (clk_en) begin
            if (cfg_ready) begin
                if (cfg_we) shadow_threshold <= cfg_threshold;
                if (cfg_commit) cfg_pending <= 1'b1;
            end
            if (room) begin
                m_valid <= p_valid;
                if (p_valid) begin
                    m_data <= (p_error != 0) ? 8'd0 : difference;
                    m_foreground <= (p_error == 0) && (difference > threshold_now);
                    m_sof <= p_sof; m_eol <= p_eol; m_tag <= p_tag; m_frameid <= p_frameid;
                    m_error <= p_error;
                    if (p_sof && cfg_pending && p_error == 0) begin
                        active_threshold <= shadow_threshold; cfg_pending <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
