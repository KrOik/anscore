module i2s_quad_rx_stub (
    input wire clk,
    input wire rst_n,
    input wire mic_d0,
    input wire mic_d1,
    input wire mic_d2,
    input wire mic_d3,
    output wire mic_bclk,
    output wire mic_ws,
    output reg sample_valid,
    output reg signed [15:0] sample0,
    output reg signed [15:0] sample1,
    output reg signed [15:0] sample2,
    output reg signed [15:0] sample3,
    output reg signed [15:0] sample4,
    output reg signed [15:0] sample5,
    output reg signed [15:0] sample_center,
    output reg [31:0] debug_bclk_edges,
    output reg [31:0] debug_ws_edges,
    output reg [31:0] debug_sample_frames,
    output reg [31:0] debug_data_edges
);

reg [15:0] clk_cnt;
reg mic_clk_d0;
reg mic_ws_d0;

reg signed [23:0] shift_left0;
reg signed [23:0] shift_right0;
reg signed [23:0] shift_left1;
reg signed [23:0] shift_right1;
reg signed [23:0] shift_left2;
reg signed [23:0] shift_right2;
reg signed [23:0] shift_center_left;
reg signed [23:0] shift_center_right;

reg mic_d0_last;
reg mic_d1_last;
reg mic_d2_last;
reg mic_d3_last;

reg [31:0] frame_activity;

wire mic_clk = clk_cnt[1];
wire mic_word_select = clk_cnt[7];
wire active_clk_rise = mic_clk && !mic_clk_d0;
wire active_ws_toggle = mic_word_select != mic_ws_d0;
wire [4:0] bit_slot = clk_cnt[6:2];
wire signed [15:0] center_left_sample = shift_center_left[23:8];
wire signed [15:0] center_right_sample = shift_center_right[23:8];
wire [16:0] center_left_abs =
    center_left_sample[15] ? {1'b0, (~center_left_sample + 16'd1)} : {1'b0, center_left_sample};
wire [16:0] center_right_abs =
    center_right_sample[15] ? {1'b0, (~center_right_sample + 16'd1)} : {1'b0, center_right_sample};

assign mic_bclk = mic_clk;
assign mic_ws = mic_word_select;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clk_cnt <= 16'd0;
        mic_clk_d0 <= 1'b0;
        mic_ws_d0 <= 1'b0;
        shift_left0 <= 24'sd0;
        shift_right0 <= 24'sd0;
        shift_left1 <= 24'sd0;
        shift_right1 <= 24'sd0;
        shift_left2 <= 24'sd0;
        shift_right2 <= 24'sd0;
        shift_center_left <= 24'sd0;
        shift_center_right <= 24'sd0;
        mic_d0_last <= 1'b0;
        mic_d1_last <= 1'b0;
        mic_d2_last <= 1'b0;
        mic_d3_last <= 1'b0;
        frame_activity <= 32'd0;
        sample_valid <= 1'b0;
        sample0 <= 16'sd0;
        sample1 <= 16'sd0;
        sample2 <= 16'sd0;
        sample3 <= 16'sd0;
        sample4 <= 16'sd0;
        sample5 <= 16'sd0;
        sample_center <= 16'sd0;
        debug_bclk_edges <= 32'd0;
        debug_ws_edges <= 32'd0;
        debug_sample_frames <= 32'd0;
        debug_data_edges <= 32'd0;
    end else begin
        clk_cnt <= clk_cnt + 16'd1;
        mic_clk_d0 <= mic_clk;
        mic_ws_d0 <= mic_word_select;
        sample_valid <= 1'b0;

        if (active_clk_rise) begin
            debug_bclk_edges <= debug_bclk_edges + 32'd1;

            if (bit_slot > 0 && bit_slot < 25) begin
                if (mic_word_select) begin
                    shift_right0 <= {shift_right0[22:0], mic_d0};
                    shift_right1 <= {shift_right1[22:0], mic_d1};
                    shift_right2 <= {shift_right2[22:0], mic_d2};
                    shift_center_right <= {shift_center_right[22:0], mic_d3};
                end else begin
                    shift_left0 <= {shift_left0[22:0], mic_d0};
                    shift_left1 <= {shift_left1[22:0], mic_d1};
                    shift_left2 <= {shift_left2[22:0], mic_d2};
                    shift_center_left <= {shift_center_left[22:0], mic_d3};
                end

                if (mic_d0 != mic_d0_last) begin
                    frame_activity <= frame_activity + 32'd1;
                end
                if (mic_d1 != mic_d1_last) begin
                    frame_activity <= frame_activity + 32'd1;
                end
                if (mic_d2 != mic_d2_last) begin
                    frame_activity <= frame_activity + 32'd1;
                end
                if (mic_d3 != mic_d3_last) begin
                    frame_activity <= frame_activity + 32'd1;
                end
            end

            mic_d0_last <= mic_d0;
            mic_d1_last <= mic_d1;
            mic_d2_last <= mic_d2;
            mic_d3_last <= mic_d3;
        end

        if (active_ws_toggle) begin
            debug_ws_edges <= debug_ws_edges + 32'd1;

            if (!mic_word_select) begin
                sample0 <= shift_right0[23:8];
                sample1 <= shift_left0[23:8];
                sample2 <= shift_right1[23:8];
                sample3 <= shift_left1[23:8];
                sample4 <= shift_right2[23:8];
                sample5 <= shift_left2[23:8];
                sample_center <= (center_right_abs >= center_left_abs) ?
                    center_right_sample : center_left_sample;
                sample_valid <= 1'b1;
                debug_sample_frames <= debug_sample_frames + 32'd1;
                debug_data_edges <= frame_activity;

                frame_activity <= 32'd0;
            end
        end
    end
end

endmodule
