// Complete grayscale HE entry: internally stores and replays the source frame.
module img_hist_he_frame #(
    parameter integer FRAME_WIDTH = 32,
    parameter integer FRAME_HEIGHT = 24,
    parameter integer COUNT_WIDTH = 16,
    parameter integer TAG_WIDTH = 16
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire start_valid, output wire start_ready,
    input wire [TAG_WIDTH-1:0] start_tag,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_gray, input wire s_sof, input wire s_eol,
    output wire m_valid, input wire m_ready, output wire [7:0] m_gray,
    output wire m_sof, output wire m_eol, output wire m_last,
    output wire [TAG_WIDTH-1:0] m_tag, output wire m_error,
    output wire done_valid, input wire done_ready, output wire done_error,
    output wire [7:0] done_error_code,
    output wire [COUNT_WIDTH-1:0] done_count,
    output wire [TAG_WIDTH-1:0] done_tag, output wire busy
);
    img_hist_frame_engine #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT), .ADAPTIVE(0),
        .COUNT_WIDTH(COUNT_WIDTH), .TAG_WIDTH(TAG_WIDTH)
    ) core (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_tag(start_tag), .start_clip_limit({COUNT_WIDTH{1'b0}}),
        .s_valid(s_valid), .s_ready(s_ready), .s_gray(s_gray),
        .s_sof(s_sof), .s_eol(s_eol),
        .m_valid(m_valid), .m_ready(m_ready), .m_gray(m_gray),
        .m_sof(m_sof), .m_eol(m_eol), .m_last(m_last), .m_tag(m_tag), .m_error(m_error),
        .done_valid(done_valid), .done_ready(done_ready), .done_error(done_error),
        .done_error_code(done_error_code), .done_count(done_count),
        .done_tag(done_tag), .busy(busy)
    );
endmodule
