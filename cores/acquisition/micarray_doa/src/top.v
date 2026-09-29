module top (
    input wire clk,
    input wire mic_d0,
    input wire mic_d1,
    input wire mic_d2,
    input wire mic_d3,
    input wire uart_rx,
    output wire mic_bclk,
    output wire mic_ws,
    output wire sk9822_ck,
    output wire sk9822_da,
    output wire uart_tx
);

reg [7:0] por_count = 8'd0;

wire rst_n = por_count[7];
wire sample_valid;
wire signed [15:0] d0_r;
wire signed [15:0] d0_l;
wire signed [15:0] d1_r;
wire signed [15:0] d1_l;
wire signed [15:0] d2_r;
wire signed [15:0] d2_l;
wire signed [15:0] d3_r;
wire signed [15:0] d3_l;
wire signed [15:0] mic0 = d0_r;
wire signed [15:0] mic1 = d0_l;
wire signed [15:0] mic2 = d1_r;
wire signed [15:0] mic3 = d1_l;
wire signed [15:0] mic4 = d2_r;
wire signed [15:0] mic5 = d2_l;
wire signed [15:0] mic_center = d3_r;
wire noise_calibrated;
wire signed [15:0] clean0;
wire signed [15:0] clean1;
wire signed [15:0] clean2;
wire signed [15:0] clean3;
wire signed [15:0] clean4;
wire signed [15:0] clean5;
wire [15:0] clean_level0;
wire [15:0] clean_level1;
wire [15:0] clean_level2;
wire [15:0] clean_level3;
wire [15:0] clean_level4;
wire [15:0] clean_level5;
wire [15:0] noise_floor0;
wire [15:0] noise_floor1;
wire [15:0] noise_floor2;
wire [15:0] noise_floor3;
wire [15:0] noise_floor4;
wire [15:0] noise_floor5;
reg [1:0] sample_decim;
wire doa_sample_valid = noise_calibrated && sample_valid && (sample_decim == 2'd0);
wire [3:0] led_index;
wire result_valid;
wire [31:0] report0;
wire [31:0] report1;
wire [31:0] report2;
wire [31:0] report3;
reg [31:0] debug_sample_frames;
wire [31:0] debug_bclk_edges = 32'd0;
wire [31:0] debug_ws_edges = 32'd0;
wire [31:0] debug_data_edges = {16'd0, d3_l[15:0]};
wire [3:0] display_led_index;
wire direction_active;

always @(posedge clk) begin
    if (!rst_n) begin
        por_count <= por_count + 1'b1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sample_decim <= 2'd0;
    end else if (sample_valid) begin
        sample_decim <= sample_decim + 1'b1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        debug_sample_frames <= 32'd0;
    end else if (sample_valid) begin
        debug_sample_frames <= debug_sample_frames + 1'b1;
    end
end

micarry_i2s_slots i2s_rx (
    .clk(clk),
    .rst_n(rst_n),
    .mic_d0(mic_d0),
    .mic_d1(mic_d1),
    .mic_d2(mic_d2),
    .mic_d3(mic_d3),
    .mic_bclk(mic_bclk),
    .mic_ws(mic_ws),
    .sample_valid(sample_valid),
    .d0_r(d0_r),
    .d0_l(d0_l),
    .d1_r(d1_r),
    .d1_l(d1_l),
    .d2_r(d2_r),
    .d2_l(d2_l),
    .d3_r(d3_r),
    .d3_l(d3_l)
);

mic_noise_filter noise_filter (
    .clk(clk),
    .rst_n(rst_n),
    .sample_valid(sample_valid),
    .mic0(mic0),
    .mic1(mic1),
    .mic2(mic2),
    .mic3(mic3),
    .mic4(mic4),
    .mic5(mic5),
    .calibrated(noise_calibrated),
    .clean0(clean0),
    .clean1(clean1),
    .clean2(clean2),
    .clean3(clean3),
    .clean4(clean4),
    .clean5(clean5),
    .level0(clean_level0),
    .level1(clean_level1),
    .level2(clean_level2),
    .level3(clean_level3),
    .level4(clean_level4),
    .level5(clean_level5),
    .floor0(noise_floor0),
    .floor1(noise_floor1),
    .floor2(noise_floor2),
    .floor3(noise_floor3),
    .floor4(noise_floor4),
    .floor5(noise_floor5)
);

micarray_doa_core #(
    .WINDOW_SAMPLES(16),
    .MAX_LAG(4),
    .MIN_TOTAL_ENERGY(32'd450),
    .MIN_DELAY_SUM(8'd1)
) doa_core (
    .clk(clk),
    .rst_n(rst_n),
    .sample_valid(doa_sample_valid),
    .sample0(clean0),
    .sample1(clean1),
    .sample2(clean2),
    .sample3(clean3),
    .sample4(clean4),
    .sample5(clean5),
    .sample_center(mic_center),
    .led_index(led_index),
    .report0(report0),
    .report1(report1),
    .report2(report2),
    .report3(report3),
    .result_valid(result_valid)
);

led_direction_filter #(
    .LED_ON_ENERGY_GATE(32'd650),
    .LED_OFF_ENERGY_GATE(32'd300),
    .LED_SCORE_GAP_GATE(16'd16),
    .LED_CONFIRM_FRAMES(3'd2)
) led_filter (
    .clk(clk),
    .rst_n(rst_n),
    .result_valid(result_valid),
    .raw_led_index(led_index),
    .report0(report0),
    .report1(report1),
    .report3(report3),
    .display_led_index(display_led_index),
    .direction_active(direction_active)
);

sk9822_driver led_driver (
    .clk(clk),
    .rst_n(rst_n),
    .led_index(display_led_index),
    .direction_active(direction_active),
    .sound_level(report0),
    .mic0_level(clean_level0),
    .mic1_level(clean_level1),
    .mic2_level(clean_level2),
    .mic3_level(clean_level3),
    .mic4_level(clean_level4),
    .mic5_level(clean_level5),
    .sk9822_ck(sk9822_ck),
    .sk9822_da(sk9822_da)
);

doa_uart_reporter uart_reporter (
    .clk(clk),
    .rst_n(rst_n),
    .result_valid(result_valid),
    .led_index(display_led_index),
    .direction_active(direction_active),
    .report0(report0),
    .report1(report1),
    .report2(report2),
    .report3(report3),
    .diag0({31'd0, noise_calibrated}),
    .diag1({noise_floor0, noise_floor1}),
    .diag2(debug_sample_frames),
    .diag3({noise_floor2, noise_floor3}),
    .uart_tx(uart_tx)
);

endmodule
