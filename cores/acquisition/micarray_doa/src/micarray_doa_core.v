module micarray_doa_core #(
    parameter integer WINDOW_SAMPLES = 64,
    parameter integer MAX_LAG = 12,
    parameter [15:0] ACTIVITY_THRESHOLD = 16'd96,
    parameter [31:0] MIN_TOTAL_ENERGY = 32'd16384,
    parameter [7:0] MIN_DELAY_SUM = 8'd3,
    parameter [3:0] LED_OFFSET = 4'd0
) (
    input wire clk,
    input wire rst_n,
    input wire sample_valid,
    input wire signed [15:0] sample0,
    input wire signed [15:0] sample1,
    input wire signed [15:0] sample2,
    input wire signed [15:0] sample3,
    input wire signed [15:0] sample4,
    input wire signed [15:0] sample5,
    input wire signed [15:0] sample_center,
    output reg [3:0] led_index,
    output reg [31:0] report0,
    output reg [31:0] report1,
    output reg [31:0] report2,
    output reg [31:0] report3,
    output reg result_valid
);

localparam integer SAMPLE_COUNT_BITS = (WINDOW_SAMPLES <= 1) ? 1 : $clog2(WINDOW_SAMPLES);
localparam integer LAG_COUNT = (MAX_LAG * 2) + 1;
localparam integer LAG_INDEX_BITS = (LAG_COUNT <= 1) ? 1 : $clog2(LAG_COUNT);
localparam integer SAMPLE_INDEX_BITS = (WINDOW_SAMPLES <= 1) ? 1 : $clog2(WINDOW_SAMPLES);

localparam [SAMPLE_COUNT_BITS-1:0] WINDOW_LAST_INDEX = WINDOW_SAMPLES - 1;
localparam [LAG_INDEX_BITS-1:0] LAG_LAST_INDEX = LAG_COUNT - 1;
localparam [7:0] MAX_LAG_U8 = MAX_LAG;

localparam [2:0] STATE_CAPTURE = 3'd0;
localparam [2:0] STATE_SCAN_PREP = 3'd1;
localparam [2:0] STATE_SCAN_ACCUM = 3'd2;
localparam [2:0] STATE_REPORT = 3'd3;

reg [2:0] state;
reg [SAMPLE_COUNT_BITS-1:0] sample_count;
reg [31:0] energy_accum;
reg [31:0] scan_energy;
reg scan_overrun;

reg [1:0] scan_pair;
reg [LAG_INDEX_BITS-1:0] scan_lag_index;
reg [SAMPLE_INDEX_BITS-1:0] scan_sample_index;
reg signed [47:0] scan_accum;
reg signed [47:0] scan_pair_best_score;
reg signed [7:0] scan_pair_best_delay;

reg signed [47:0] pair0_best_score;
reg signed [47:0] pair1_best_score;
reg signed [47:0] pair2_best_score;
reg signed [7:0] pair0_best_delay;
reg signed [7:0] pair1_best_delay;
reg signed [7:0] pair2_best_delay;

reg signed [15:0] buf0 [0:WINDOW_SAMPLES - 1];
reg signed [15:0] buf1 [0:WINDOW_SAMPLES - 1];
reg signed [15:0] buf2 [0:WINDOW_SAMPLES - 1];
reg signed [15:0] buf3 [0:WINDOW_SAMPLES - 1];
reg signed [15:0] buf4 [0:WINDOW_SAMPLES - 1];
reg signed [15:0] buf5 [0:WINDOW_SAMPLES - 1];

integer sector_i;
reg signed [31:0] sector_score_candidate;
reg [3:0] best_led_comb;
reg signed [31:0] best_sector_score_comb;
reg signed [31:0] second_sector_score_comb;
reg second_sector_valid_comb;

wire [16:0] abs0 = sample0[15] ? {1'b0, (~sample0 + 16'd1)} : {1'b0, sample0};
wire [16:0] abs1 = sample1[15] ? {1'b0, (~sample1 + 16'd1)} : {1'b0, sample1};
wire [16:0] abs2 = sample2[15] ? {1'b0, (~sample2 + 16'd1)} : {1'b0, sample2};
wire [16:0] abs3 = sample3[15] ? {1'b0, (~sample3 + 16'd1)} : {1'b0, sample3};
wire [16:0] abs4 = sample4[15] ? {1'b0, (~sample4 + 16'd1)} : {1'b0, sample4};
wire [16:0] abs5 = sample5[15] ? {1'b0, (~sample5 + 16'd1)} : {1'b0, sample5};
wire [16:0] abs_center = sample_center[15] ? {1'b0, (~sample_center + 16'd1)} : {1'b0, sample_center};
wire [31:0] sample_energy_sum = {11'd0, abs0}
    + {11'd0, abs1}
    + {11'd0, abs2}
    + {11'd0, abs3}
    + {11'd0, abs4}
    + {11'd0, abs5}
    + {11'd0, abs_center};
wire [31:0] next_energy_accum = energy_accum + sample_energy_sum;

wire signed [8:0] scan_lag_signed9 =
    $signed({1'b0, scan_lag_index}) - $signed({1'b0, MAX_LAG_U8});
wire signed [7:0] scan_lag_signed = scan_lag_signed9[7:0];
wire [7:0] scan_lag_abs = scan_lag_signed[7] ? (~scan_lag_signed + 8'd1) : scan_lag_signed[7:0];
wire [SAMPLE_INDEX_BITS:0] valid_overlap_count = WINDOW_SAMPLES - scan_lag_abs;
wire overlap_valid = ({1'b0, scan_sample_index} < valid_overlap_count);
wire [SAMPLE_INDEX_BITS:0] raw_index_a =
    scan_lag_signed[7] ? ({1'b0, scan_sample_index} + scan_lag_abs) : {1'b0, scan_sample_index};
wire [SAMPLE_INDEX_BITS:0] raw_index_b =
    scan_lag_signed[7] ? {1'b0, scan_sample_index} : ({1'b0, scan_sample_index} + scan_lag_abs);
wire [SAMPLE_INDEX_BITS-1:0] index_a =
    (raw_index_a >= WINDOW_SAMPLES) ? WINDOW_LAST_INDEX : raw_index_a[SAMPLE_INDEX_BITS-1:0];
wire [SAMPLE_INDEX_BITS-1:0] index_b =
    (raw_index_b >= WINDOW_SAMPLES) ? WINDOW_LAST_INDEX : raw_index_b[SAMPLE_INDEX_BITS-1:0];

reg signed [15:0] scan_value_a;
reg signed [15:0] scan_value_b;
wire signed [31:0] scan_product = scan_value_a * scan_value_b;
wire signed [47:0] scan_score_next =
    scan_accum + (overlap_valid ? {{16{scan_product[31]}}, scan_product} : 48'sd0);
wire scan_last_sample = (scan_sample_index == WINDOW_LAST_INDEX);
wire scan_last_lag = (scan_lag_index == LAG_LAST_INDEX);
wire scan_last_pair = (scan_pair == 2'd2);
wire scan_score_is_new =
    (scan_lag_index == {LAG_INDEX_BITS{1'b0}}) || (scan_score_next > scan_pair_best_score);
wire signed [47:0] scan_best_score_next =
    scan_score_is_new ? scan_score_next : scan_pair_best_score;
wire signed [7:0] scan_best_delay_next =
    scan_score_is_new ? scan_lag_signed : scan_pair_best_delay;

wire signed [15:0] vector_x_comb =
    $signed(pair0_best_delay) + $signed(pair1_best_delay) - $signed(pair2_best_delay);
wire signed [15:0] vector_y_comb =
    ($signed(pair1_best_delay) + $signed(pair2_best_delay)) <<< 1;
wire [7:0] pair0_delay_abs = pair0_best_delay[7] ? (~pair0_best_delay + 8'd1) : pair0_best_delay[7:0];
wire [7:0] pair1_delay_abs = pair1_best_delay[7] ? (~pair1_best_delay + 8'd1) : pair1_best_delay[7:0];
wire [7:0] pair2_delay_abs = pair2_best_delay[7] ? (~pair2_best_delay + 8'd1) : pair2_best_delay[7:0];
wire [7:0] delay_sum_comb =
    pair0_delay_abs + pair1_delay_abs + pair2_delay_abs;
wire saturated_delay_comb =
    (pair0_delay_abs == MAX_LAG_U8) &&
    (pair1_delay_abs == MAX_LAG_U8) &&
    (pair2_delay_abs == MAX_LAG_U8);
wire signal_present_comb = (scan_energy >= MIN_TOTAL_ENERGY);
wire direction_valid_comb = signal_present_comb && (delay_sum_comb >= MIN_DELAY_SUM) && !saturated_delay_comb;
wire [9:0] confidence_raw_comb = {2'd0, delay_sum_comb} << 2;
wire [5:0] confidence_comb = |confidence_raw_comb[9:6] ? 6'h3F : confidence_raw_comb[5:0];
wire [7:0] status_byte_comb = {scan_overrun, direction_valid_comb, confidence_comb};
wire [3:0] rotated_led_comb = best_led_comb + LED_OFFSET;
wire signed [31:0] score_gap_comb =
    best_sector_score_comb - (second_sector_valid_comb ? second_sector_score_comb : 32'sd0);
wire [15:0] score_gap_report =
    (score_gap_comb <= 32'sd0) ? 16'd0 : (|score_gap_comb[31:16] ? 16'hFFFF : score_gap_comb[15:0]);
wire [15:0] best_sector_score_report =
    (best_sector_score_comb <= 32'sd0) ? 16'd0 : (|best_sector_score_comb[31:16] ? 16'hFFFF : best_sector_score_comb[15:0]);

always @* begin
    case (scan_pair)
        2'd0: begin
            scan_value_a = buf0[index_a];
            scan_value_b = buf3[index_b];
        end
        2'd1: begin
            scan_value_a = buf1[index_a];
            scan_value_b = buf4[index_b];
        end
        default: begin
            scan_value_a = buf2[index_a];
            scan_value_b = buf5[index_b];
        end
    endcase
end

always @* begin
    best_led_comb = 4'd0;
    best_sector_score_comb = (vector_y_comb * 16'sd256);
    second_sector_score_comb = 32'sd0;
    second_sector_valid_comb = 1'b0;

    for (sector_i = 1; sector_i < 12; sector_i = sector_i + 1) begin
        case (sector_i)
            1: sector_score_candidate = (vector_x_comb * 16'sd128) + (vector_y_comb * 16'sd222);
            2: sector_score_candidate = (vector_x_comb * 16'sd222) + (vector_y_comb * 16'sd128);
            3: sector_score_candidate = (vector_x_comb * 16'sd256);
            4: sector_score_candidate = (vector_x_comb * 16'sd222) - (vector_y_comb * 16'sd128);
            5: sector_score_candidate = (vector_x_comb * 16'sd128) - (vector_y_comb * 16'sd222);
            6: sector_score_candidate = -(vector_y_comb * 16'sd256);
            7: sector_score_candidate = -(vector_x_comb * 16'sd128) - (vector_y_comb * 16'sd222);
            8: sector_score_candidate = -(vector_x_comb * 16'sd222) - (vector_y_comb * 16'sd128);
            9: sector_score_candidate = -(vector_x_comb * 16'sd256);
            10: sector_score_candidate = -(vector_x_comb * 16'sd222) + (vector_y_comb * 16'sd128);
            default: sector_score_candidate = -(vector_x_comb * 16'sd128) + (vector_y_comb * 16'sd222);
        endcase
        if (sector_score_candidate > best_sector_score_comb) begin
            second_sector_score_comb = best_sector_score_comb;
            second_sector_valid_comb = 1'b1;
            best_sector_score_comb = sector_score_candidate;
            best_led_comb = sector_i[3:0];
        end else if (!second_sector_valid_comb || (sector_score_candidate > second_sector_score_comb)) begin
            second_sector_score_comb = sector_score_candidate;
            second_sector_valid_comb = 1'b1;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= STATE_CAPTURE;
        sample_count <= {SAMPLE_COUNT_BITS{1'b0}};
        energy_accum <= 32'd0;
        scan_energy <= 32'd0;
        scan_overrun <= 1'b0;
        scan_pair <= 2'd0;
        scan_lag_index <= {LAG_INDEX_BITS{1'b0}};
        scan_sample_index <= {SAMPLE_INDEX_BITS{1'b0}};
        scan_accum <= 48'sd0;
        scan_pair_best_score <= 48'sd0;
        scan_pair_best_delay <= 8'sd0;
        pair0_best_score <= 48'sd0;
        pair1_best_score <= 48'sd0;
        pair2_best_score <= 48'sd0;
        pair0_best_delay <= 8'sd0;
        pair1_best_delay <= 8'sd0;
        pair2_best_delay <= 8'sd0;
        led_index <= 4'd0;
        report0 <= 32'd0;
        report1 <= 32'd0;
        report2 <= 32'd0;
        report3 <= 32'd0;
        result_valid <= 1'b0;
    end else begin
        result_valid <= 1'b0;

        case (state)
            STATE_CAPTURE: begin
                if (sample_valid) begin
                    buf0[sample_count] <= sample0;
                    buf1[sample_count] <= sample1;
                    buf2[sample_count] <= sample2;
                    buf3[sample_count] <= sample3;
                    buf4[sample_count] <= sample4;
                    buf5[sample_count] <= sample5;

                    if (sample_count == WINDOW_LAST_INDEX) begin
                        sample_count <= {SAMPLE_COUNT_BITS{1'b0}};
                        energy_accum <= 32'd0;
                        scan_energy <= next_energy_accum;
                        scan_overrun <= 1'b0;
                        scan_pair <= 2'd0;
                        scan_lag_index <= {LAG_INDEX_BITS{1'b0}};
                        scan_sample_index <= {SAMPLE_INDEX_BITS{1'b0}};
                        scan_accum <= 48'sd0;
                        scan_pair_best_score <= 48'sd0;
                        scan_pair_best_delay <= -$signed({1'b0, MAX_LAG_U8});
                        state <= STATE_SCAN_ACCUM;
                    end else begin
                        sample_count <= sample_count + 1'b1;
                        energy_accum <= next_energy_accum;
                    end
                end
            end

            STATE_SCAN_ACCUM: begin
                if (sample_valid) begin
                    scan_overrun <= 1'b1;
                end

                if (scan_last_sample) begin
                    if (scan_last_lag) begin
                        case (scan_pair)
                            2'd0: begin
                                pair0_best_score <= scan_best_score_next;
                                pair0_best_delay <= scan_best_delay_next;
                            end
                            2'd1: begin
                                pair1_best_score <= scan_best_score_next;
                                pair1_best_delay <= scan_best_delay_next;
                            end
                            default: begin
                                pair2_best_score <= scan_best_score_next;
                                pair2_best_delay <= scan_best_delay_next;
                            end
                        endcase

                        if (scan_last_pair) begin
                            state <= STATE_REPORT;
                        end else begin
                            scan_pair <= scan_pair + 1'b1;
                            scan_lag_index <= {LAG_INDEX_BITS{1'b0}};
                            scan_sample_index <= {SAMPLE_INDEX_BITS{1'b0}};
                            scan_accum <= 48'sd0;
                            scan_pair_best_score <= 48'sd0;
                            scan_pair_best_delay <= -$signed({1'b0, MAX_LAG_U8});
                        end
                    end else begin
                        scan_lag_index <= scan_lag_index + 1'b1;
                        scan_sample_index <= {SAMPLE_INDEX_BITS{1'b0}};
                        scan_accum <= 48'sd0;
                        scan_pair_best_score <= scan_best_score_next;
                        scan_pair_best_delay <= scan_best_delay_next;
                    end
                end else begin
                    scan_sample_index <= scan_sample_index + 1'b1;
                    scan_accum <= scan_score_next;
                end
            end

            STATE_REPORT: begin
                report0 <= scan_energy;
                report1 <= {
                    pair0_best_delay[7:0],
                    pair1_best_delay[7:0],
                    pair2_best_delay[7:0],
                    status_byte_comb
                };
                report2 <= {vector_x_comb[15:0], vector_y_comb[15:0]};
                report3 <= {
                    score_gap_report,
                    best_sector_score_report
                };

                if (direction_valid_comb) begin
                    if (rotated_led_comb >= 4'd12) begin
                        led_index <= rotated_led_comb - 4'd12;
                    end else begin
                        led_index <= rotated_led_comb;
                    end
                end

                result_valid <= 1'b1;
                state <= STATE_CAPTURE;
            end

            default: begin
                state <= STATE_CAPTURE;
            end
        endcase
    end
end

endmodule
