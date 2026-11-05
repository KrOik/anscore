// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Exact ordered balanced integer transport; see README and COST for protocol/schedule.
module exact_1d_transport #(
    parameter integer NUM_BINS = 16,
    parameter integer KEY_W = 16,
    parameter integer MASS_W = 16,
    parameter integer TAG_W = 8,
    localparam integer L = (NUM_BINS > 1) ? $clog2(NUM_BINS) : 0,
    localparam integer TOTAL_W = MASS_W + L,
    localparam integer COST_W = TOTAL_W + KEY_W,
    localparam integer INDEX_W = (L > 0) ? L : 1,
    localparam integer PTR_W = (NUM_BINS > 1) ? $clog2(NUM_BINS+1) : 1,
    localparam integer COUNT_W = (NUM_BINS > 1) ? $clog2(2*NUM_BINS) : 1
) (
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire signed [KEY_W-1:0] s_key,
    input wire [MASS_W-1:0] s_source, input wire [MASS_W-1:0] s_target,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire m_summary, output wire m_last,
    output wire [INDEX_W-1:0] m_source_index, output wire [INDEX_W-1:0] m_target_index,
    output wire signed [KEY_W-1:0] m_source_key, output wire signed [KEY_W-1:0] m_target_key,
    output wire [MASS_W-1:0] m_quantity,
    output wire [COST_W-1:0] m_cost,
    output wire [TOTAL_W-1:0] m_source_total, output wire [TOTAL_W-1:0] m_target_total,
    output wire [COUNT_W-1:0] m_flow_count,
    output wire [1:0] m_error, output wire [TAG_W-1:0] m_tag
);
    generate
        if (NUM_BINS < 1 || NUM_BINS > 64) begin : bad_bins
            TRANSPORT_REJECT_NUM_BINS invalid_parameter();
        end
        if (KEY_W < 2 || KEY_W > 24) begin : bad_key
            TRANSPORT_REJECT_KEY_W invalid_parameter();
        end
        if (MASS_W < 1 || MASS_W > 24) begin : bad_mass
            TRANSPORT_REJECT_MASS_W invalid_parameter();
        end
        if (TAG_W < 1 || TAG_W > 32) begin : bad_tag
            TRANSPORT_REJECT_TAG_W invalid_parameter();
        end
    endgenerate

    localparam integer ROW_W = KEY_W + 2*MASS_W;
    localparam integer ALU_W = COST_W+1;
    localparam integer MUL_W = (MASS_W > 1) ? $clog2(MASS_W) : 1;
    localparam [4:0] S_CAPTURE=0,S_ADD_A=1,S_ADD_B=2,S_CAP_NEXT=3,
        S_A_REQ=4,S_A_LOAD=5,S_B_REQ=6,S_B_LOAD=7,S_CHOOSE=8,
        S_DISTANCE=9,S_MULTIPLY=10,S_COST=11,S_FLOW=12,
        S_SUB_A=13,S_SUB_B=14,S_ADVANCE=15,S_SUMMARY=16;
    reg [4:0] state;
    reg [ROW_W-1:0] rows [0:NUM_BINS-1];
    reg [ROW_W-1:0] ram_q, source_row, target_row;
    reg [PTR_W-1:0] capture_count, source_ptr, target_ptr;
    reg [TOTAL_W-1:0] source_total,target_total;
    reg [MASS_W-1:0] pending_source,pending_target;
    reg signed [KEY_W-1:0] previous_key;
    reg [MASS_W-1:0] source_residual,target_residual,quantity,multiplier;
    reg [COST_W-1:0] multiplicand,product,running_cost;
    reg [MUL_W-1:0] multiply_index;
    reg [COUNT_W-1:0] flow_count;
    reg [TAG_W-1:0] tag;
    reg [1:0] error_bits;
    reg target_cached;
    wire signed [KEY_W-1:0] source_key=source_row[ROW_W-1:2*MASS_W];
    wire signed [KEY_W-1:0] target_key=target_row[ROW_W-1:2*MASS_W];
    wire input_fire=s_valid && s_ready;
    wire ram_read=(state==S_A_REQ && source_ptr<NUM_BINS)
        || (state==S_B_REQ && target_ptr<NUM_BINS);
    wire [INDEX_W-1:0] ram_address=input_fire ? capture_count[INDEX_W-1:0]
        : ((state==S_A_REQ) ? source_ptr[INDEX_W-1:0] : target_ptr[INDEX_W-1:0]);

    // This single scheduled port never reads and writes on the same edge.
    always @(posedge clk) begin
        if (!rst) begin
            if (input_fire)
                rows[ram_address] <= {s_key,s_source,s_target};
            else if (ram_read)
                ram_q <= rows[ram_address];
        end
    end

    reg [ALU_W-1:0] alu_a,alu_b;
    reg alu_subtract;
    wire [ALU_W-1:0] alu_y = alu_a + (alu_b ^ {ALU_W{alu_subtract}})
        + {{(ALU_W-1){1'b0}},alu_subtract};
    always @* begin
        alu_a=0; alu_b=0; alu_subtract=0;
        case (state)
            S_ADD_A: begin
                alu_a={{(ALU_W-TOTAL_W){1'b0}},source_total};
                alu_b={{(ALU_W-MASS_W){1'b0}},pending_source};
            end
            S_ADD_B: begin
                alu_a={{(ALU_W-TOTAL_W){1'b0}},target_total};
                alu_b={{(ALU_W-MASS_W){1'b0}},pending_target};
            end
            S_DISTANCE: begin
                alu_subtract=1;
                // Sign-extend BEFORE subtraction; result is the unsigned magnitude.
                if (source_key >= target_key) begin
                    alu_a={{(ALU_W-KEY_W){source_key[KEY_W-1]}},source_key};
                    alu_b={{(ALU_W-KEY_W){target_key[KEY_W-1]}},target_key};
                end else begin
                    alu_a={{(ALU_W-KEY_W){target_key[KEY_W-1]}},target_key};
                    alu_b={{(ALU_W-KEY_W){source_key[KEY_W-1]}},source_key};
                end
            end
            S_MULTIPLY: begin
                alu_a={1'b0,product};
                alu_b=multiplier[0] ? {1'b0,multiplicand} : {ALU_W{1'b0}};
            end
            S_COST: begin alu_a={1'b0,running_cost}; alu_b={1'b0,product}; end
            S_SUB_A: begin
                alu_a={{(ALU_W-MASS_W){1'b0}},source_residual};
                alu_b={{(ALU_W-MASS_W){1'b0}},quantity}; alu_subtract=1;
            end
            S_SUB_B: begin
                alu_a={{(ALU_W-MASS_W){1'b0}},target_residual};
                alu_b={{(ALU_W-MASS_W){1'b0}},quantity}; alu_subtract=1;
            end
            default: begin end
        endcase
    end

    assign s_ready=!rst && state==S_CAPTURE;
    assign m_valid=!rst && (state==S_FLOW || state==S_SUMMARY);
    assign m_summary=state==S_SUMMARY;
    assign m_last=m_summary;
    assign m_source_index=m_summary ? {INDEX_W{1'b0}} : source_ptr[INDEX_W-1:0];
    assign m_target_index=m_summary ? {INDEX_W{1'b0}} : target_ptr[INDEX_W-1:0];
    assign m_source_key=m_summary ? {KEY_W{1'b0}} : source_key;
    assign m_target_key=m_summary ? {KEY_W{1'b0}} : target_key;
    assign m_quantity=m_summary ? {MASS_W{1'b0}} : quantity;
    assign m_cost=running_cost;
    assign m_source_total=source_total;
    assign m_target_total=target_total;
    assign m_flow_count=flow_count;
    assign m_error=error_bits;
    assign m_tag=tag;

    always @(posedge clk) begin
        if (rst) begin
            state<=S_CAPTURE; capture_count<=0; source_ptr<=0; target_ptr<=0;
            source_total<=0; target_total<=0; error_bits<=0; tag<=0;
            running_cost<=0; flow_count<=0; target_cached<=0;
            multiply_index<=0;
        end else begin
            case (state)
                S_CAPTURE: if (input_fire) begin
                    pending_source<=s_source; pending_target<=s_target;
                    previous_key<=s_key;
                    if (capture_count==0) tag<=s_tag;
                    else if (s_key <= previous_key) error_bits[1]<=1;
                    capture_count<=capture_count+1'b1;
                    state<=S_ADD_A;
                end
                S_ADD_A: begin source_total<=alu_y[TOTAL_W-1:0]; state<=S_ADD_B; end
                S_ADD_B: begin target_total<=alu_y[TOTAL_W-1:0]; state<=S_CAP_NEXT; end
                S_CAP_NEXT: begin
                    if (capture_count < NUM_BINS) state<=S_CAPTURE;
                    else begin
                        error_bits[0]<=source_total!=target_total;
                        if (error_bits[1] || source_total!=target_total || source_total==0)
                            state<=S_SUMMARY;
                        else state<=S_A_REQ;
                    end
                end
                S_A_REQ: begin
                    if (source_ptr==NUM_BINS) state<=S_SUMMARY;
                    else state<=S_A_LOAD;
                end
                S_A_LOAD: begin
                    source_row<=ram_q;
                    source_residual<=ram_q[2*MASS_W-1:MASS_W];
                    if (ram_q[2*MASS_W-1:MASS_W]==0) begin
                        source_ptr<=source_ptr+1'b1; state<=S_A_REQ;
                    end else if (target_cached) state<=S_CHOOSE;
                    else state<=S_B_REQ;
                end
                S_B_REQ: begin
                    if (target_ptr==NUM_BINS) state<=S_SUMMARY;
                    else state<=S_B_LOAD;
                end
                S_B_LOAD: begin
                    target_row<=ram_q; target_residual<=ram_q[MASS_W-1:0];
                    if (ram_q[MASS_W-1:0]==0) begin
                        target_ptr<=target_ptr+1'b1; state<=S_B_REQ;
                    end else begin target_cached<=1; state<=S_CHOOSE; end
                end
                S_CHOOSE: begin
                    quantity<=(source_residual < target_residual) ? source_residual : target_residual;
                    state<=S_DISTANCE;
                end
                S_DISTANCE: begin
                    multiplicand<={{(COST_W-KEY_W){1'b0}},alu_y[KEY_W-1:0]};
                    multiplier<=quantity; product<=0; multiply_index<=0; state<=S_MULTIPLY;
                end
                S_MULTIPLY: begin
                    product<=alu_y[COST_W-1:0];
                    multiplier<=multiplier>>1; multiplicand<=multiplicand<<1;
                    if (multiply_index==MASS_W-1) state<=S_COST;
                    else multiply_index<=multiply_index+1'b1;
                end
                S_COST: begin
                    running_cost<=alu_y[COST_W-1:0]; flow_count<=flow_count+1'b1; state<=S_FLOW;
                end
                S_FLOW: if (m_ready) state<=S_SUB_A;
                S_SUB_A: begin source_residual<=alu_y[MASS_W-1:0]; state<=S_SUB_B; end
                S_SUB_B: begin target_residual<=alu_y[MASS_W-1:0]; state<=S_ADVANCE; end
                S_ADVANCE: begin
                    if (source_residual==0) source_ptr<=source_ptr+1'b1;
                    if (target_residual==0) begin target_ptr<=target_ptr+1'b1; target_cached<=0; end
                    if (source_residual==0) state<=S_A_REQ;
                    else state<=S_B_REQ;
                end
                S_SUMMARY: if (m_ready) begin
                    state<=S_CAPTURE; capture_count<=0; source_ptr<=0; target_ptr<=0;
                    source_total<=0; target_total<=0; error_bits<=0; running_cost<=0;
                    flow_count<=0; target_cached<=0;
                end
                default: state<=S_CAPTURE;
            endcase
        end
    end
endmodule
`default_nettype wire
