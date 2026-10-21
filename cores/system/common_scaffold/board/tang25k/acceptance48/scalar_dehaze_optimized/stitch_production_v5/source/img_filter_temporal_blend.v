// implementation_draft_unverified. Aligned TWO-PIXEL kernel, no frame storage.
// Both s_data/s_history belong to one atomic input transfer at the same position.
// mix = round((alpha*current + (256-alpha)*history)/256), alpha=0..256.
// Missing history or motion difference above threshold selects current pixel.
// Invalid alpha emits m_error=1 with zero data, never a successful blend.
module img_filter_temporal_blend #(parameter PIXEL_W = 8)(
    input wire clk, rst_n, clk_en,
    input wire [PIXEL_W-1:0] s_data, s_history,
    input wire s_history_available,
    input wire [8:0] cfg_current_weight_q8,
    input wire [PIXEL_W-1:0] cfg_motion_threshold,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_error,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    reg [PIXEL_W-1:0] difference, result;
    reg [8:0] history_weight;
    reg [PIXEL_W+8:0] weighted_current, weighted_history;
    reg [PIXEL_W+9:0] weighted_sum;
    reg error;
    wire [PIXEL_W:0] packed_output;
    always @* begin
        difference = s_data >= s_history ? s_data-s_history : s_history-s_data;
        history_weight = 9'd256 - cfg_current_weight_q8;
        weighted_current = s_data * cfg_current_weight_q8;
        weighted_history = s_history * history_weight;
        weighted_sum = {1'b0, weighted_current} + {1'b0, weighted_history} + 128;
        error = cfg_current_weight_q8 > 9'd256;
        if (error) result = {PIXEL_W{1'b0}};
        else if (!s_history_available || difference > cfg_motion_threshold) result = s_data;
        else result = weighted_sum[PIXEL_W+7:8];
    end
    img_filter_stream_register #(.DATA_W(PIXEL_W+1)) output_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data({error, result}), .s_valid(s_valid), .s_ready(s_ready),
        .s_sof(s_sof), .s_eol(s_eol), .m_data(packed_output),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
    assign {m_error, m_data} = packed_output;
endmodule
