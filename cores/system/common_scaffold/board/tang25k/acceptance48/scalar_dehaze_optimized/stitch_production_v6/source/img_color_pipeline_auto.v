// RGB888 closed-loop gray-world AWB -> CCM -> contrast/brightness -> Gamma.
// OUTPUT_YCBCR adds the integer full-range BT.601 RGB-to-YCbCr stage.
// Transfers require shared clk_en && valid && ready. Configuration writes
// fill shadow registers; stop input and drain before global commit. Every
// stage applies its pending configuration at its next accepted SOF.
module img_color_pipeline_auto #(
    parameter OUTPUT_YCBCR=0,
    parameter AWB_SUM_WIDTH=48
)(
    input wire clk,rst_n,clk_en,
    input wire [23:0] s_data,
    input wire s_valid,s_sof,s_eol,
    output wire s_ready,
    output wire [23:0] m_data,
    output wire m_valid,m_sof,m_eol,
    input wire m_ready,
    input wire stats_flush,
    output wire stats_flush_ready,
    input wire [15:0] cfg_awb_min_gain,cfg_awb_max_gain,
    output wire [15:0] applied_gain_r,applied_gain_g,applied_gain_b,
    output wire [31:0] applied_statistics_frame,
    output wire [7:0] awb_error,
    output wire awb_update_pending,
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
    input wire [7:0] cfg_gamma_addr,cfg_gamma_value,
    input wire cfg_gamma_enable,
    output wire cfg_gamma_ready,
    output wire [2:0] cfg_gamma_complete,
    input wire cfg_commit_valid,
    output wire cfg_commit_ready,
    output wire [3:0] cfg_pending,
    output wire cfg_error,gamma_active
);
wire [23:0] white_data;
wire white_valid,white_sof,white_eol,white_ready,input_ready;
wire downstream_commit_ready;
reg [2:0] awb_inflight;
assign s_ready=rst_n && input_ready;
// The downstream chain cannot see the AWB statistics/gain elastic buffers.
// Include both the upstream presentation and the final AWB buffer here so a
// quiescent global commit cannot overtake a previously accepted RGB pixel.
assign cfg_commit_ready=rst_n && clk_en && downstream_commit_ready &&
                        !s_valid && !white_valid && !awb_inflight;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) awb_inflight<=0;
    else if(clk_en) begin
        case({s_valid && s_ready,white_valid && white_ready})
          2'b10:awb_inflight<=awb_inflight+1'b1;
          2'b01:awb_inflight<=awb_inflight-1'b1;
          default:awb_inflight<=awb_inflight;
        endcase
    end
end
img_isp_awb_auto #(.SUM_WIDTH(AWB_SUM_WIDTH)) white_balance (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(s_data),.s_valid(s_valid && rst_n),.s_ready(input_ready),.s_sof(s_sof),.s_eol(s_eol),
    .m_data(white_data),.m_valid(white_valid),.m_ready(white_ready),.m_sof(white_sof),.m_eol(white_eol),
    .stats_flush(stats_flush),.stats_flush_ready(stats_flush_ready),
    .cfg_min_gain(cfg_awb_min_gain),.cfg_max_gain(cfg_awb_max_gain),
    .applied_gain_r(applied_gain_r),.applied_gain_g(applied_gain_g),.applied_gain_b(applied_gain_b),
    .applied_statistics_frame(applied_statistics_frame),.error_code(awb_error),
    .update_pending(awb_update_pending)
);
// The manual-gain stage is held at its reset unity setting; all automatic
// white balance is performed above. Reuse the same configured color stages
// as the manual pipeline rather than maintaining divergent arithmetic paths.
img_color_pipeline_draft #(.OUTPUT_YCBCR(OUTPUT_YCBCR)) color (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(white_data),.s_valid(white_valid),.s_ready(white_ready),.s_sof(white_sof),.s_eol(white_eol),
    .m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),
    .cfg_gain_we(1'b0),.cfg_gain_r(16'd256),.cfg_gain_g(16'd256),.cfg_gain_b(16'd256),.cfg_gain_ready(),
    .cfg_ccm_we(cfg_ccm_we),.cfg_ccm_index(cfg_ccm_index),.cfg_ccm_value(cfg_ccm_value),.cfg_ccm_ready(cfg_ccm_ready),
    .cfg_adjust_we(cfg_adjust_we),.cfg_brightness(cfg_brightness),.cfg_contrast(cfg_contrast),.cfg_adjust_ready(cfg_adjust_ready),
    .cfg_gamma_we(cfg_gamma_we),.cfg_gamma_channel(cfg_gamma_channel),.cfg_gamma_addr(cfg_gamma_addr),
    .cfg_gamma_value(cfg_gamma_value),.cfg_gamma_enable(cfg_gamma_enable),.cfg_gamma_ready(cfg_gamma_ready),
    .cfg_gamma_complete(cfg_gamma_complete),.cfg_commit_valid(cfg_commit_valid && cfg_commit_ready),
    .cfg_commit_ready(downstream_commit_ready),.cfg_pending(cfg_pending),.cfg_error(cfg_error),.gamma_active(gamma_active)
);
endmodule
