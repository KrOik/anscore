// Complete gray-world feedback path: RGB statistics -> gain solver -> gain.
// Latest computed result is retained while a previous frame-boundary update
// is pending. This decouples the statistics and configuration paths, avoiding
// a circular wait between the next SOF and the gain-result consumer.
module img_isp_awb_auto #(parameter SUM_WIDTH=48)(
    input wire clk,rst_n,clk_en,
    input wire [23:0] s_data,
    input wire s_valid,s_sof,s_eol,
    output wire s_ready,
    output wire [23:0] m_data,
    output wire m_valid,m_sof,m_eol,
    input wire m_ready,
    input wire stats_flush,
    output wire stats_flush_ready,
    input wire [15:0] cfg_min_gain,cfg_max_gain,
    output reg [15:0] applied_gain_r,applied_gain_g,applied_gain_b,
    output reg [31:0] applied_statistics_frame,
    output reg [7:0] error_code,
    output wire update_pending
);
wire [23:0] stat_data;
wire stat_valid,stat_ready,stat_sof,stat_eol;
wire stats_valid,stats_ready,stats_overflow,stats_protocol_error;
wire [SUM_WIDTH-1:0] stats_sum_r,stats_sum_g,stats_sum_b;
wire [31:0] stats_count,stats_lines,stats_frame;
wire result_valid,gain_cfg_ready,gain_cfg_pending;
wire [15:0] result_r,result_g,result_b;
wire [31:0] result_frame;
wire [7:0] result_error;
reg latest_valid;
reg [15:0] latest_r,latest_g,latest_b;
reg [31:0] latest_frame;
reg [15:0] staged_r,staged_g,staged_b;
reg [31:0] staged_frame;
wire apply_update=latest_valid && gain_cfg_ready;
assign update_pending=latest_valid || gain_cfg_pending;
img_isp_awb_stats #(.SUM_WIDTH(SUM_WIDTH)) statistics (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),
    .m_data(stat_data),.m_valid(stat_valid),.m_ready(stat_ready),.m_sof(stat_sof),.m_eol(stat_eol),
    .stats_flush(stats_flush),.stats_flush_ready(stats_flush_ready),
    .stats_valid(stats_valid),.stats_ready(stats_ready),
    .stats_sum_r(stats_sum_r),.stats_sum_g(stats_sum_g),.stats_sum_b(stats_sum_b),
    .stats_pixel_count(stats_count),.stats_line_count(stats_lines),.stats_frame_id(stats_frame),
    .stats_overflow(stats_overflow),.protocol_error(stats_protocol_error)
);
img_isp_awb_autogain #(.SUM_WIDTH(SUM_WIDTH)) gain_solver (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.stats_valid(stats_valid),.stats_ready(stats_ready),
    .stats_sum_r(stats_sum_r),.stats_sum_g(stats_sum_g),.stats_sum_b(stats_sum_b),
    .stats_pixel_count(stats_count),.stats_frame_id(stats_frame),.stats_overflow(stats_overflow),
    .cfg_min_gain(cfg_min_gain),.cfg_max_gain(cfg_max_gain),
    .gain_valid(result_valid),.gain_ready(1'b1),.gain_r(result_r),.gain_g(result_g),.gain_b(result_b),
    .gain_frame_id(result_frame),.gain_error(result_error)
);
img_isp_awb_gain gains (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(stat_data),.s_valid(stat_valid),.s_ready(stat_ready),.s_sof(stat_sof),.s_eol(stat_eol),
    .m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),
    .cfg_we(apply_update),.cfg_commit(apply_update),
    .cfg_gain_r(latest_r),.cfg_gain_g(latest_g),.cfg_gain_b(latest_b),
    .cfg_ready(gain_cfg_ready),.cfg_pending(gain_cfg_pending)
);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        latest_valid<=0;latest_r<=256;latest_g<=256;latest_b<=256;latest_frame<=0;
        staged_r<=256;staged_g<=256;staged_b<=256;staged_frame<=0;
        applied_gain_r<=256;applied_gain_g<=256;applied_gain_b<=256;applied_statistics_frame<=0;error_code<=0;
    end else if(clk_en) begin
        if(stats_protocol_error) error_code[4]<=1;
        if(apply_update) begin
            latest_valid<=0;staged_r<=latest_r;staged_g<=latest_g;staged_b<=latest_b;
            staged_frame<=latest_frame;
        end
        if(gain_cfg_pending && stat_valid && stat_ready && stat_sof)begin
            applied_gain_r<=staged_r;applied_gain_g<=staged_g;applied_gain_b<=staged_b;
            applied_statistics_frame<=staged_frame;
        end
        if(result_valid) begin
            error_code<=error_code | result_error | (stats_protocol_error ? 8'h10 : 8'h00);
            // Invalid counts/config/overflow do not replace the last valid gains.
            // Zero-channel saturation is a diagnostic but has a defined result.
            if((result_error & 8'hf7)==0) begin
                latest_valid<=1;latest_r<=result_r;latest_g<=result_g;latest_b<=result_b;latest_frame<=result_frame;
            end
        end
    end
end
endmodule
