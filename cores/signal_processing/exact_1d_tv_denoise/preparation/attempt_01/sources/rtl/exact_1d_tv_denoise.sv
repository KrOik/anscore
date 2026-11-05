// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none

// Exact TV proximal operator. The KKT/tube derivation is in MATHEMATICS.md.
// All RAM reads are owned by a fully captured frame; neither RAM is reset.
module exact_1d_tv_denoise #(
    parameter integer N = 16,
    parameter integer DATA_W = 16,
    parameter integer TAG_W = 8,
    localparam integer INDEX_W = (N <= 1) ? 1 : $clog2(N),
    localparam integer DEN_W = (N < 1) ? 1 : $clog2(N + 1),
    localparam integer NUM_W = DATA_W + $clog2(((N < 1) ? 1 : N) + 4)
) (
    input  wire                       clk,
    input  wire                       rst,
    input  wire                       s_valid,
    output wire                       s_ready,
    input  wire signed [DATA_W-1:0]    s_data,
    input  wire [DATA_W-1:0]           s_lambda,
    input  wire [TAG_W-1:0]            s_tag,
    output wire                       m_valid,
    input  wire                       m_ready,
    output wire signed [NUM_W-1:0]     m_numerator,
    output wire [DEN_W-1:0]            m_denominator,
    output wire [INDEX_W-1:0]          m_index,
    output wire                       m_last,
    output wire [TAG_W-1:0]            m_tag
);
    localparam integer SAFE_N = ((N >= 1) && (N <= 64)) ? N : 1;
    localparam integer CMP_W = NUM_W + DEN_W + 2;
    localparam integer STEP_W = (DEN_W <= 1) ? 1 : $clog2(DEN_W);
    localparam [DEN_W-1:0] COUNT_ONE = 1;
    localparam [DEN_W-1:0] LAST_INDEX = N - 1;
    localparam [DEN_W-1:0] FRAME_END = N;
    localparam [STEP_W-1:0] LAST_BIT = DEN_W - 1;
    localparam [3:0] ST_CAPTURE = 0, ST_BLOCK_INIT = 1,
        ST_READ_SAMPLE = 2, ST_MAKE_BOUNDS = 3, ST_COMPARE_INIT = 4,
        ST_COMPARE_LEFT = 5, ST_COMPARE_RIGHT = 6, ST_COMPARE_DONE = 7,
        ST_WRITE_BLOCK = 8, ST_FINISH_BLOCK = 9,
        ST_OUTPUT_READ = 10, ST_OUTPUT_HOLD = 11;

    generate
        if ((N < 1) || (N > 64)) begin : g_invalid_n
            exact_1d_tv_denoise_invalid_N__see_README invalid_parameter();
        end
        if ((DATA_W < 2) || (DATA_W > 24)) begin : g_invalid_w
            exact_1d_tv_denoise_invalid_DATA_W__see_README invalid_parameter();
        end
        if ((TAG_W < 1) || (TAG_W > 32)) begin : g_invalid_tag
            exact_1d_tv_denoise_invalid_TAG_W__see_README invalid_parameter();
        end
    endgenerate

    reg [3:0] state;
    reg [DEN_W-1:0] input_index, block_start, scan_index, scan_count;
    reg [DEN_W-1:0] write_index, output_index;
    reg [DATA_W-1:0] lambda_reg;
    reg [TAG_W-1:0] tag_reg;
    reg signed [1:0] left_sign, emit_right_sign;
    reg signed [DATA_W-1:0] sample_mem [0:SAFE_N-1];
    reg signed [DATA_W-1:0] sample_read;
    reg [NUM_W+DEN_W-1:0] result_mem [0:SAFE_N-1];
    reg [NUM_W+DEN_W-1:0] output_word;
    reg signed [NUM_W-1:0] segment_sum;
    reg have_bounds;
    reg signed [NUM_W-1:0] candidate_lo, candidate_hi;
    reg [DEN_W-1:0] candidate_den;
    reg signed [NUM_W-1:0] lower_num, upper_num, emit_num;
    reg [DEN_W-1:0] lower_den, upper_den, lower_end, upper_end;
    reg [DEN_W-1:0] emit_den, emit_end;
    reg [1:0] compare_stage;
    reg [STEP_W-1:0] compare_bit;
    reg signed [CMP_W-1:0] compare_acc, left_shift, right_shift;
    reg [DEN_W-1:0] left_factor, right_factor;
    reg signed [NUM_W-1:0] compare_a, compare_b;
    reg [DEN_W-1:0] compare_a_den, compare_b_den;

    wire signed [NUM_W-1:0] sample_extended =
        $signed({{(NUM_W-DATA_W){sample_read[DATA_W-1]}}, sample_read});
    wire signed [NUM_W-1:0] lambda_extended =
        $signed({{(NUM_W-DATA_W){1'b0}}, lambda_reg});
    wire signed [NUM_W-1:0] next_sum = segment_sum + sample_extended;
    wire signed [NUM_W-1:0] twice_lambda = lambda_extended <<< 1;
    wire signed [NUM_W-1:0] lower_offset = (left_sign == 2'sd1) ?
        -twice_lambda : ((left_sign == -2'sd1) ? {NUM_W{1'b0}} : -lambda_extended);
    wire signed [NUM_W-1:0] upper_offset = (left_sign == -2'sd1) ?
        twice_lambda : ((left_sign == 2'sd1) ? {NUM_W{1'b0}} : lambda_extended);
    wire signed [NUM_W-1:0] endpoint_offset = (left_sign == 2'sd1) ?
        -lambda_extended : ((left_sign == -2'sd1) ? lambda_extended : {NUM_W{1'b0}});
    wire terminal_node = (scan_index == LAST_INDEX);
    wire signed [NUM_W-1:0] next_lo = next_sum +
        (terminal_node ? endpoint_offset : lower_offset);
    wire signed [NUM_W-1:0] next_hi = next_sum +
        (terminal_node ? endpoint_offset : upper_offset);
    wire [DEN_W-1:0] next_den = scan_count + COUNT_ONE;
    wire [DEN_W-1:0] next_end = scan_index + COUNT_ONE;

    // One explicitly shared two's-complement add/subtract path. The R-bit
    // partial products/differences are bounded in MATHEMATICS.md.
    wire compare_subtract = (state == ST_COMPARE_RIGHT);
    wire signed [CMP_W-1:0] selected_shift = compare_subtract ? right_shift : left_shift;
    wire selected_factor_bit = compare_subtract ? right_factor[0] : left_factor[0];
    wire [CMP_W-1:0] compare_operand = selected_factor_bit ? selected_shift : {CMP_W{1'b0}};
    wire [CMP_W:0] compare_sum = {1'b0, compare_acc} +
        {1'b0, (compare_operand ^ {CMP_W{compare_subtract}})} +
        {{CMP_W{1'b0}}, compare_subtract};

    assign s_ready = !rst && (state == ST_CAPTURE);
    assign m_valid = !rst && (state == ST_OUTPUT_HOLD);
    assign m_numerator = $signed(output_word[NUM_W+DEN_W-1:DEN_W]);
    assign m_denominator = output_word[DEN_W-1:0];
    assign m_index = output_index[INDEX_W-1:0];
    assign m_last = (output_index == LAST_INDEX);
    assign m_tag = tag_reg;

    always @* begin
        compare_a = candidate_lo;
        compare_a_den = candidate_den;
        compare_b = upper_num;
        compare_b_den = upper_den;
        case (compare_stage)
            2'd1: begin
                compare_a = candidate_hi;
                compare_b = lower_num;
                compare_b_den = lower_den;
            end
            2'd2: begin
                compare_b = lower_num;
                compare_b_den = lower_den;
            end
            2'd3: compare_a = candidate_hi;
            default: begin end
        endcase
    end

    always @(posedge clk) begin
        if (!rst) begin
            if ((state == ST_CAPTURE) && s_valid && s_ready)
                sample_mem[input_index] <= s_data;
            else if (state == ST_READ_SAMPLE)
                sample_read <= sample_mem[scan_index];
            if (state == ST_WRITE_BLOCK)
                result_mem[write_index] <= {emit_num, emit_den};
            else if (state == ST_OUTPUT_READ)
                output_word <= result_mem[output_index];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_CAPTURE;
            input_index <= {DEN_W{1'b0}};
            output_index <= {DEN_W{1'b0}};
        end else begin
            case (state)
                ST_CAPTURE: if (s_valid && s_ready) begin
                    if (input_index == {DEN_W{1'b0}}) begin
                        lambda_reg <= s_lambda;
                        tag_reg <= s_tag;
                    end
                    if (input_index == LAST_INDEX) begin
                        block_start <= {DEN_W{1'b0}};
                        left_sign <= 2'sd0;
                        state <= ST_BLOCK_INIT;
                    end else input_index <= input_index + COUNT_ONE;
                end
                ST_BLOCK_INIT: begin
                    scan_index <= block_start;
                    scan_count <= {DEN_W{1'b0}};
                    segment_sum <= {NUM_W{1'b0}};
                    have_bounds <= 1'b0;
                    state <= ST_READ_SAMPLE;
                end
                ST_READ_SAMPLE: state <= ST_MAKE_BOUNDS;
                ST_MAKE_BOUNDS: begin
                    segment_sum <= next_sum;
                    scan_count <= next_den;
                    candidate_lo <= next_lo;
                    candidate_hi <= next_hi;
                    candidate_den <= next_den;
                    if (lambda_reg == {DATA_W{1'b0}}) begin
                        emit_num <= sample_extended;
                        emit_den <= COUNT_ONE;
                        emit_end <= next_end;
                        emit_right_sign <= 2'sd0;
                        write_index <= block_start;
                        state <= ST_WRITE_BLOCK;
                    end else if (!have_bounds) begin
                        lower_num <= next_lo;
                        upper_num <= next_hi;
                        lower_den <= next_den;
                        upper_den <= next_den;
                        lower_end <= next_end;
                        upper_end <= next_end;
                        have_bounds <= 1'b1;
                        if (terminal_node) begin
                            emit_num <= next_lo;
                            emit_den <= next_den;
                            emit_end <= FRAME_END;
                            emit_right_sign <= 2'sd0;
                            write_index <= block_start;
                            state <= ST_WRITE_BLOCK;
                        end else begin
                            scan_index <= next_end;
                            state <= ST_READ_SAMPLE;
                        end
                    end else begin
                        compare_stage <= 2'd0;
                        state <= ST_COMPARE_INIT;
                    end
                end
                ST_COMPARE_INIT: begin
                    compare_acc <= {CMP_W{1'b0}};
                    left_shift <= $signed({{(CMP_W-NUM_W){compare_a[NUM_W-1]}}, compare_a});
                    right_shift <= $signed({{(CMP_W-NUM_W){compare_b[NUM_W-1]}}, compare_b});
                    left_factor <= compare_b_den;
                    right_factor <= compare_a_den;
                    compare_bit <= {STEP_W{1'b0}};
                    state <= ST_COMPARE_LEFT;
                end
                ST_COMPARE_LEFT: begin
                    compare_acc <= $signed(compare_sum[CMP_W-1:0]);
                    left_shift <= left_shift <<< 1;
                    left_factor <= left_factor >> 1;
                    if (compare_bit == LAST_BIT) begin
                        compare_bit <= {STEP_W{1'b0}};
                        state <= ST_COMPARE_RIGHT;
                    end else compare_bit <= compare_bit + 1'b1;
                end
                ST_COMPARE_RIGHT: begin
                    compare_acc <= $signed(compare_sum[CMP_W-1:0]);
                    right_shift <= right_shift <<< 1;
                    right_factor <= right_factor >> 1;
                    if (compare_bit == LAST_BIT) state <= ST_COMPARE_DONE;
                    else compare_bit <= compare_bit + 1'b1;
                end
                ST_COMPARE_DONE: begin
                    if ((compare_stage == 2'd0) && (compare_acc > 0)) begin
                        emit_num <= upper_num;
                        emit_den <= upper_den;
                        emit_end <= upper_end;
                        emit_right_sign <= 2'sd1;
                        write_index <= block_start;
                        state <= ST_WRITE_BLOCK;
                    end else if ((compare_stage == 2'd1) && (compare_acc < 0)) begin
                        emit_num <= lower_num;
                        emit_den <= lower_den;
                        emit_end <= lower_end;
                        emit_right_sign <= -2'sd1;
                        write_index <= block_start;
                        state <= ST_WRITE_BLOCK;
                    end else if (compare_stage == 2'd3) begin
                        if (compare_acc <= 0) begin
                            upper_num <= candidate_hi;
                            upper_den <= candidate_den;
                            upper_end <= next_end;
                        end
                        if (terminal_node) begin
                            emit_num <= candidate_lo;
                            emit_den <= candidate_den;
                            emit_end <= FRAME_END;
                            emit_right_sign <= 2'sd0;
                            write_index <= block_start;
                            state <= ST_WRITE_BLOCK;
                        end else begin
                            scan_index <= next_end;
                            state <= ST_READ_SAMPLE;
                        end
                    end else begin
                        if ((compare_stage == 2'd2) && (compare_acc >= 0)) begin
                            lower_num <= candidate_lo;
                            lower_den <= candidate_den;
                            lower_end <= next_end;
                        end
                        compare_stage <= compare_stage + 1'b1;
                        state <= ST_COMPARE_INIT;
                    end
                end
                ST_WRITE_BLOCK: begin
                    if (write_index == emit_end - COUNT_ONE) state <= ST_FINISH_BLOCK;
                    else write_index <= write_index + COUNT_ONE;
                end
                ST_FINISH_BLOCK: begin
                    if (emit_end == FRAME_END) begin
                        output_index <= {DEN_W{1'b0}};
                        state <= ST_OUTPUT_READ;
                    end else begin
                        block_start <= emit_end;
                        left_sign <= emit_right_sign;
                        state <= ST_BLOCK_INIT;
                    end
                end
                ST_OUTPUT_READ: state <= ST_OUTPUT_HOLD;
                ST_OUTPUT_HOLD: if (m_ready && m_valid) begin
                    if (output_index == LAST_INDEX) begin
                        input_index <= {DEN_W{1'b0}};
                        state <= ST_CAPTURE;
                    end else begin
                        output_index <= output_index + COUNT_ONE;
                        state <= ST_OUTPUT_READ;
                    end
                end
                default: begin
                    state <= ST_CAPTURE;
                    input_index <= {DEN_W{1'b0}};
                end
            endcase
        end
    end
endmodule
`default_nettype wire
