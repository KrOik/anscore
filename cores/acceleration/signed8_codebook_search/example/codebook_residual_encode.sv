// Original ANSCORE, Apache-2.0. Exact code selection then RNE S8 residuals.
module codebook_residual_encode #(
    parameter MAX_CODES=16, MAX_DIMS=16, TAG_W=8
)(
    input wire clk, rst,
    input wire cfg_valid, output wire cfg_ready,
    input wire [6:0] cfg_code, input wire [8:0] cfg_dim,
    input wire cfg_first, input wire signed [7:0] cfg_value,
    output wire cfg_rsp_valid, input wire cfg_rsp_ready,
    output wire [1:0] cfg_status,
    output wire [6:0] cfg_rsp_code, output wire [8:0] cfg_rsp_dim,
    input wire c_valid, output wire c_ready,
    input wire [6:0] c_codes, input wire [8:0] c_dims,
    input wire [TAG_W-1:0] c_tag, input wire [3:0] c_residual_shift,
    input wire s_valid, output wire s_ready, input wire signed [7:0] s_value,
    output wire m_valid, input wire m_ready,
    output wire [1:0] m_error, output wire [5:0] m_code,
    output wire [23:0] m_distance, m_margin,
    output wire m_second_valid, output wire [TAG_W-1:0] m_tag,
    output wire e_valid, input wire e_ready,
    output wire signed [7:0] e_value,
    output wire e_clip, e_inexact, output wire [7:0] e_dim,
    output wire e_last, output wire [TAG_W-1:0] e_tag
);
    wire replay_valid, replay_ready, replay_last;
    wire [7:0] replay_dim;
    wire [TAG_W-1:0] replay_tag;
    wire signed [8:0] replay_residual;
    wire [TAG_W+8:0] encoded_tag;
    reg [3:0] shift_q;
    always @(posedge clk) begin
        if(rst) shift_q<=0;
        else if(c_valid && c_ready) shift_q<=c_residual_shift;
    end
    signed8_codebook_search #(.MAX_CODES(MAX_CODES),.MAX_DIMS(MAX_DIMS),.TAG_W(TAG_W)) search(
        .clk(clk),.rst(rst),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
        .cfg_code(cfg_code),.cfg_dim(cfg_dim),.cfg_first(cfg_first),.cfg_value(cfg_value),
        .cfg_rsp_valid(cfg_rsp_valid),.cfg_rsp_ready(cfg_rsp_ready),.cfg_status(cfg_status),
        .cfg_rsp_code(cfg_rsp_code),.cfg_rsp_dim(cfg_rsp_dim),
        .c_valid(c_valid),.c_ready(c_ready),.c_codes(c_codes),.c_dims(c_dims),.c_tag(c_tag),
        .s_valid(s_valid),.s_ready(s_ready),.s_value(s_value),
        .m_valid(m_valid),.m_ready(m_ready),.m_error(m_error),.m_code(m_code),
        .m_distance(m_distance),.m_margin(m_margin),.m_second_valid(m_second_valid),.m_tag(m_tag),
        .r_valid(replay_valid),.r_ready(replay_ready),.r_dim(replay_dim),
        .r_value(),.r_original(),.r_residual(replay_residual),
        .r_last(replay_last),.r_tag(replay_tag)
    );
    stream_requantize #(.IN_W(9),.OUT_W(8),.TAG_W(TAG_W+9)) quantize(
        .clk(clk),.rst(rst),.s_valid(replay_valid),.s_ready(replay_ready),
        .s_data(replay_residual),.s_shift(shift_q),.s_tag({replay_tag,replay_dim,replay_last}),
        .m_valid(e_valid),.m_ready(e_ready),.m_data(e_value),
        .m_clip(e_clip),.m_inexact(e_inexact),.m_tag(encoded_tag)
    );
    assign e_tag=encoded_tag[TAG_W+8:9];
    assign e_dim=encoded_tag[8:1];
    assign e_last=encoded_tag[0];
endmodule
