// Complete grayscale-guided frame filter. Shared CE: all handshakes require CE.
// I=s_guide is unsigned 8-bit, p=s_p is unsigned Q1.15 (0..32768).
// Command snapshots geometry/radius/epsilon/tag. Edge-replicated square boxes.
// epsilon is in squared 8-bit guide units, NOT normalized [0,1] units.
// The guide and source are an aligned pair in ONE atomic input transaction.
module img_dh_guided_frame #(
    parameter integer MAX_WIDTH=64, MAX_HEIGHT=64, MAX_RADIUS=3,
    parameter integer TAG_WIDTH=16
) (
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [15:0] cmd_width,cmd_height,
    input wire [3:0] cmd_radius,
    input wire [31:0] cmd_epsilon,
    input wire [TAG_WIDTH-1:0] cmd_tag,
    input wire [7:0] s_guide,
    input wire [15:0] s_p,
    input wire s_valid,s_sof,s_eol,
    output wire s_ready,
    output wire [15:0] m_q,
    output wire m_valid,m_sof,m_eol,m_eof,
    input wire m_ready,
    output wire [TAG_WIDTH-1:0] m_tag,
    output wire rsp_valid,
    input wire rsp_ready,
    output wire [3:0] rsp_error,
    output wire [TAG_WIDTH-1:0] rsp_tag,
    output wire busy
);
    reg [TAG_WIDTH-1:0] tag;
    reg running;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin tag<=0;running<=0;end
        else if(clk_en) begin
            if(cmd_valid && cmd_ready) begin tag<=cmd_tag;running<=1;end
            if(rsp_valid && rsp_ready) running<=0;
        end
    end
    assign m_tag=tag;
    assign rsp_tag=tag;
    assign busy=running;
    img_dh_guided_refine #(.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),
        .MAX_RADIUS(MAX_RADIUS)) u_filter (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cfg_valid(cmd_valid),.cfg_ready(cmd_ready),
        .cfg_width(cmd_width),.cfg_height(cmd_height),.cfg_radius(cmd_radius),
        .cfg_epsilon(cmd_epsilon),.s_guide_gray(s_guide),.s_t(s_p),
        .s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(s_ready),
        .m_t(m_q),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof),
        .m_ready(m_ready),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),
        .debug_divide_quotient(),.debug_first_a_value(),.debug_first_b_value(),
        .debug_first_sum_i(),.debug_first_sum_p(),.debug_first_sum_ii(),
        .debug_first_sum_ip(),.debug_frame_error_flags(),
        .debug_first_a_numerator(),.debug_first_a_denominator(),
        .debug_first_b_numerator(),.debug_first_b_denominator(),
        .debug_second_q_numerator(),.debug_second_q_denominator(),
        .debug_first_q_sum_a(),.debug_first_q_sum_b(),
        .debug_first_q_numerator(),.debug_first_q_denominator(),
        .debug_a_coeff_1(),.debug_a_coeff_3(),.debug_a_coeff_4(),
        .debug_b_coeff_1(),.debug_b_coeff_3(),.debug_b_coeff_4(),
        .debug_a3_sum_i(),.debug_a3_sum_p(),.debug_a3_sum_ii(),.debug_a3_sum_ip(),
        .debug_a4_sum_i(),.debug_a4_sum_p(),.debug_a4_sum_ii(),.debug_a4_sum_ip()
    );
endmodule
