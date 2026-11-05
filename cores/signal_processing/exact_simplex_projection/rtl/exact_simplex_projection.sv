// SPDX-License-Identifier: Apache-2.0
// Exact rational projection; no division, rounding or saturation.
module exact_simplex_projection #(
    parameter integer N = 16,
    parameter integer DATA_W = 16,
    parameter integer TAG_W = 8
) (
    input  wire clk,
    input  wire rst,
    input  wire s_valid,
    output wire s_ready,
    input  wire signed [DATA_W-1:0] s_data,
    input  wire [DATA_W-1:0] s_mass,
    input  wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input  wire m_ready,
    output wire [DATA_W+((N>1)?$clog2(N):0)-1:0] m_numerator,
    output wire [((N>1)?$clog2(N+1):1)-1:0] m_denominator,
    output wire [((N>1)?$clog2(N):1)-1:0] m_index,
    output wire m_last,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer L = (N>1)?$clog2(N):0;
    localparam integer INDEX_W = (N>1)?$clog2(N):1;
    localparam integer COUNT_W = (N>1)?$clog2(N+1):1;
    localparam integer NUM_W = DATA_W+L;
    localparam integer AR_W = DATA_W+L+2;
    localparam integer PROD_W = DATA_W+COUNT_W+1;
    localparam [INDEX_W-1:0] LAST_INDEX = N-1;
    localparam [COUNT_W-1:0] N_COUNT = N;
    localparam [3:0] LOAD=0, INITIALIZE=1, PASS_READ=2, PASS_MULT=3,
        PASS_CHECK=4, PASS_END=5, OUTPUT_READ=6, OUTPUT_MULT=7,
        OUTPUT_CHECK=8, HOLD=9;

    generate
        if (N<1 || N>64 || DATA_W<2 || DATA_W>24 || TAG_W<1 || TAG_W>32) begin : bad_parameters
            exact_simplex_projection_invalid_parameters__see_README invalid_configuration();
        end
    endgenerate

    reg [3:0] state;
    reg [INDEX_W-1:0] index;
    reg signed [DATA_W-1:0] samples [0:N-1];
    reg signed [DATA_W-1:0] read_data;
    reg [N-1:0] active;
    reg [COUNT_W-1:0] active_k, kept_count, round_count;
    reg signed [AR_W-1:0] sum_reg, threshold;
    reg signed [PROD_W-1:0] product_reg;
    reg [DATA_W-1:0] mass;
    reg [TAG_W-1:0] frame_tag;
    reg [NUM_W-1:0] numerator;

    wire signed [AR_W-1:0] sample_extended =
        {{(AR_W-DATA_W){s_data[DATA_W-1]}},s_data};
    wire signed [AR_W-1:0] read_extended =
        {{(AR_W-DATA_W){read_data[DATA_W-1]}},read_data};
    // A zero prefix makes every legal k positive before signed multiplication.
    wire signed [COUNT_W:0] positive_k = $signed({1'b0,active_k});
    wire signed [PROD_W-1:0] full_product = read_data * positive_k;
    wire signed [AR_W-1:0] product_extended =
        {{(AR_W-PROD_W){product_reg[PROD_W-1]}},product_reg};
    wire signed [AR_W-1:0] mass_extended =
        $signed({{(AR_W-DATA_W){1'b0}},mass});
    wire above_threshold = product_extended>threshold;

    reg signed [AR_W-1:0] alu_a, alu_b;
    reg alu_sub;
    // One explicitly selected two's-complement add/subtract datapath.
    wire [AR_W:0] alu_full = {1'b0,alu_a}
        + {1'b0,(alu_b ^ {AR_W{alu_sub}})}
        + {{AR_W{1'b0}},alu_sub};
    wire signed [AR_W-1:0] alu_result = $signed(alu_full[AR_W-1:0]);
    always @* begin
        alu_a = sum_reg;
        alu_b = read_extended;
        alu_sub = 1'b0;
        case (state)
            LOAD: begin
                alu_a = (index==0)?{AR_W{1'b0}}:sum_reg;
                alu_b = sample_extended;
            end
            INITIALIZE, PASS_END: begin
                alu_a = sum_reg;
                alu_b = mass_extended;
                alu_sub = 1'b1;
            end
            OUTPUT_CHECK: begin
                alu_a = product_extended;
                alu_b = threshold;
                alu_sub = 1'b1;
            end
            default: begin end
        endcase
    end

    assign s_ready = !rst && state==LOAD;
    assign m_valid = !rst && state==HOLD;
    assign m_numerator = numerator;
    assign m_denominator = active_k;
    assign m_index = index;
    assign m_last = index==LAST_INDEX;
    assign m_tag = frame_tag;

    // One synchronous write port and one registered synchronous read port.
    // LOAD and READ states cannot coincide. Every address is overwritten before use.
    always @(posedge clk) begin
        if (!rst) begin
            if (s_valid && s_ready) samples[index] <= s_data;
            if (state==PASS_READ || state==OUTPUT_READ) read_data <= samples[index];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= LOAD;
            index <= {INDEX_W{1'b0}};
        end else begin
            case (state)
                LOAD: if (s_valid && s_ready) begin
                    sum_reg <= alu_result;
                    if (index==0) begin
                        mass <= s_mass;
                        frame_tag <= s_tag;
                    end
                    if (index==LAST_INDEX) begin
                        index <= {INDEX_W{1'b0}};
                        active_k <= N_COUNT;
                        round_count <= {COUNT_W{1'b0}};
                        state <= INITIALIZE;
                    end else index <= index+1'b1;
                end
                INITIALIZE: begin
                    sum_reg <= {AR_W{1'b0}};
                    kept_count <= {COUNT_W{1'b0}};
                    if (mass==0) begin
                        active <= {N{1'b0}};
                        active_k <= {{(COUNT_W-1){1'b0}},1'b1};
                        threshold <= {AR_W{1'b0}};
                        state <= OUTPUT_READ;
                    end else begin
                        active <= {N{1'b1}};
                        threshold <= alu_result;
                        round_count <= {{(COUNT_W-1){1'b0}},1'b1};
                        state <= PASS_READ;
                    end
                end
                PASS_READ: state <= PASS_MULT;
                PASS_MULT: begin
                    product_reg <= full_product;
                    state <= PASS_CHECK;
                end
                PASS_CHECK: begin
                    // k and threshold remain fixed for the entire pass.
                    // Equality has zero projected value and is deliberately removed.
                    if (active[index] && above_threshold) begin
                        sum_reg <= alu_result;
                        kept_count <= kept_count+1'b1;
                    end else active[index] <= 1'b0;
                    if (index==LAST_INDEX) state <= PASS_END;
                    else begin index <= index+1'b1; state <= PASS_READ; end
                end
                PASS_END: begin
                    index <= {INDEX_W{1'b0}};
                    if (kept_count==active_k) state <= OUTPUT_READ;
                    else begin
                        active_k <= kept_count;
                        threshold <= alu_result;
                        sum_reg <= {AR_W{1'b0}};
                        kept_count <= {COUNT_W{1'b0}};
                        round_count <= round_count+1'b1;
                        state <= PASS_READ;
                    end
                end
                OUTPUT_READ: state <= OUTPUT_MULT;
                OUTPUT_MULT: begin
                    product_reg <= full_product;
                    state <= OUTPUT_CHECK;
                end
                OUTPUT_CHECK: begin
                    if (mass!=0 && above_threshold)
                        numerator <= alu_result[NUM_W-1:0];
                    else numerator <= {NUM_W{1'b0}};
                    state <= HOLD;
                end
                HOLD: if (m_ready) begin
                    if (index==LAST_INDEX) begin
                        index <= {INDEX_W{1'b0}};
                        state <= LOAD;
                    end else begin index <= index+1'b1; state <= OUTPUT_READ; end
                end
                default: begin state <= LOAD; index <= {INDEX_W{1'b0}}; end
            endcase
        end
    end
endmodule
