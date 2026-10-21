// Manual-color pipeline. Small-frame group regression: run_group_regression.py.
// Synthesis, timing and board integration remain unmeasured.
// RGB888 -> AWB gains -> CCM -> brightness/contrast -> gamma -> optional YCbCr.
// Native protocol: transfers require shared clk_en && valid && ready.
// Load every desired shadow parameter before a global commit handshake.
// Quiesce input and drain the pipeline before committing. The commit is
// applied independently at each stage's next accepted SOF.
module img_color_pipeline_draft #(
    parameter OUTPUT_YCBCR = 0
)(
    input wire clk, rst_n, clk_en,
    input wire [23:0] s_data,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [23:0] m_data,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready,

    input wire cfg_gain_we,
    input wire [15:0] cfg_gain_r, cfg_gain_g, cfg_gain_b,
    output wire cfg_gain_ready,
    input wire cfg_ccm_we,
    input wire [3:0] cfg_ccm_index,
    input wire signed [15:0] cfg_ccm_value,
    output wire cfg_ccm_ready,
    input wire cfg_adjust_we,
    input wire signed [9:0] cfg_brightness,
    input wire [15:0] cfg_contrast,
    output wire cfg_adjust_ready,
    input wire cfg_gamma_we,
    input wire [1:0] cfg_gamma_channel,
    input wire [7:0] cfg_gamma_addr, cfg_gamma_value,
    input wire cfg_gamma_enable,
    output wire cfg_gamma_ready,
    output wire [2:0] cfg_gamma_complete,
    input wire cfg_commit_valid,
    output wire cfg_commit_ready,
    output wire [3:0] cfg_pending,
    output wire cfg_error,
    output wire gamma_active
);
wire [23:0] gain_data, ccm_data, adjust_data, gamma_data;
wire gain_valid,gain_sof,gain_eol,gain_ready;
wire ccm_valid,ccm_sof,ccm_eol,ccm_ready;
wire adjust_valid,adjust_sof,adjust_eol,adjust_ready;
wire gamma_valid,gamma_sof,gamma_eol,gamma_ready;
wire gain_cfg_ready,ccm_cfg_ready,adjust_cfg_ready,gamma_cfg_ready;
wire gain_input_ready;
wire ccm_error,gamma_error;
wire commit_fire;

assign cfg_gain_ready = rst_n && gain_cfg_ready;
assign cfg_ccm_ready = rst_n && ccm_cfg_ready;
assign cfg_adjust_ready = rst_n && adjust_cfg_ready;
assign cfg_gamma_ready = rst_n && gamma_cfg_ready;
// Prevent a partial global commit: gamma requires a complete inactive LUT.
// A disabled gamma commit may proceed without loading the table.
assign cfg_commit_ready = rst_n && clk_en &&
    gain_cfg_ready && ccm_cfg_ready && adjust_cfg_ready && gamma_cfg_ready &&
    (!cfg_gamma_enable || (&cfg_gamma_complete)) &&
    !(s_valid || gain_valid || ccm_valid || adjust_valid || gamma_valid || m_valid) &&
    !(cfg_gain_we || cfg_ccm_we || cfg_adjust_we || cfg_gamma_we);
assign commit_fire = cfg_commit_valid && cfg_commit_ready;
assign cfg_error = ccm_error || gamma_error;
assign s_ready = rst_n && gain_input_ready;

img_isp_awb_gain gains (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(s_data),.s_valid(s_valid && rst_n),.s_ready(gain_input_ready),.s_sof(s_sof),.s_eol(s_eol),
    .m_data(gain_data),.m_valid(gain_valid),.m_ready(gain_ready),.m_sof(gain_sof),.m_eol(gain_eol),
    .cfg_we(cfg_gain_we && rst_n),.cfg_commit(commit_fire),
    .cfg_gain_r(cfg_gain_r),.cfg_gain_g(cfg_gain_g),.cfg_gain_b(cfg_gain_b),
    .cfg_ready(gain_cfg_ready),.cfg_pending(cfg_pending[0])
);
img_isp_ccm matrix (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(gain_data),.s_valid(gain_valid),.s_ready(gain_ready),.s_sof(gain_sof),.s_eol(gain_eol),
    .m_data(ccm_data),.m_valid(ccm_valid),.m_ready(ccm_ready),.m_sof(ccm_sof),.m_eol(ccm_eol),
    .cfg_we(cfg_ccm_we && rst_n),.cfg_commit(commit_fire),.cfg_index(cfg_ccm_index),.cfg_value(cfg_ccm_value),
    .cfg_ready(ccm_cfg_ready),.cfg_pending(cfg_pending[1]),.cfg_error(ccm_error)
);
img_isp_brightness_contrast adjust (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(ccm_data),.s_valid(ccm_valid),.s_ready(ccm_ready),.s_sof(ccm_sof),.s_eol(ccm_eol),
    .m_data(adjust_data),.m_valid(adjust_valid),.m_ready(adjust_ready),.m_sof(adjust_sof),.m_eol(adjust_eol),
    .cfg_we(cfg_adjust_we && rst_n),.cfg_commit(commit_fire),
    .cfg_brightness(cfg_brightness),.cfg_contrast(cfg_contrast),
    .cfg_ready(adjust_cfg_ready),.cfg_pending(cfg_pending[2])
);
img_isp_gamma_lut gamma (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(adjust_data),.s_valid(adjust_valid),.s_ready(adjust_ready),.s_sof(adjust_sof),.s_eol(adjust_eol),
    .m_data(gamma_data),.m_valid(gamma_valid),.m_ready(gamma_ready),.m_sof(gamma_sof),.m_eol(gamma_eol),
    .cfg_we(cfg_gamma_we && rst_n),.cfg_channel(cfg_gamma_channel),.cfg_addr(cfg_gamma_addr),.cfg_value(cfg_gamma_value),
    .cfg_commit(commit_fire),.cfg_enable(cfg_gamma_enable),.cfg_ready(gamma_cfg_ready),
    .cfg_pending(cfg_pending[3]),.cfg_error(gamma_error),.cfg_lut_complete(cfg_gamma_complete),.active_enable(gamma_active)
);
generate if (OUTPUT_YCBCR != 0) begin : ycbcr_output
    img_isp_colorspace csc (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .s_data(gamma_data),.s_valid(gamma_valid),.s_ready(gamma_ready),.s_sof(gamma_sof),.s_eol(gamma_eol),
        .m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),
        .cfg_we(1'b0),.cfg_commit(1'b0),.cfg_yuv_to_rgb(1'b0),.cfg_ready(),.cfg_pending()
    );
end else begin : rgb_output
    assign m_data = gamma_data;
    assign m_valid = gamma_valid;
    assign m_sof = gamma_sof;
    assign m_eol = gamma_eol;
    assign gamma_ready = m_ready;
end endgenerate
endmodule
