module ntt256_systolic_full_stream_monitor (
    input  wire        clk,
    input  wire        rst_n,
    output reg         done,
    output reg         pass,
    output reg         fail,
    output reg  [15:0] bubble_count,
    output reg  [15:0] issue_count,
    output reg  [15:0] output_count,
    output reg  [15:0] bank_check_count,
    output reg  [15:0] first_latency,
    output reg  [15:0] transition_mask,
    output reg  [31:0] signature
);

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_INTT = 3'd3;
localparam [2:0] OP_KEM_INTT = 3'd2;

localparam [1:0] S_ISSUE = 2'd0;
localparam [1:0] S_DRAIN = 2'd1;
localparam [1:0] S_DONE  = 2'd2;

localparam integer META_LATENCY = 24;
localparam [15:0] TOTAL_SLOTS = 16'd3072;
localparam [15:0] EXPECTED_LATENCY = 16'd23;
localparam [15:0] EXPECTED_TRANSITIONS = 16'hc409;
localparam [31:0] EXPECTED_SIGNATURE = 32'hc4090c17;

reg [1:0] state;
reg [15:0] elapsed_cycles;
reg [1:0] issue_op_num;
reg [2:0] issue_stage;
reg [6:0] issue_bfly;
reg [1:0] expect_op_num;
reg [2:0] expect_stage;
reg [6:0] expect_bfly;
reg out_started;
reg [2:0] last_out_op;

reg valid_meta [0:META_LATENCY-1];
reg [1:0] op_num_meta [0:META_LATENCY-1];
reg [2:0] op_meta [0:META_LATENCY-1];
reg [2:0] stage_meta [0:META_LATENCY-1];
reg [6:0] bfly_meta [0:META_LATENCY-1];
reg [7:0] addr_a_meta [0:META_LATENCY-1];
reg [7:0] addr_b_meta [0:META_LATENCY-1];
reg [1:0] bank_a_meta [0:META_LATENCY-1];
reg [1:0] bank_b_meta [0:META_LATENCY-1];

integer i;

wire issue_valid = (state == S_ISSUE);
wire [2:0] issue_op = seq_op(issue_op_num);
wire issue_inverse = is_inverse_op(issue_op);
wire [7:0] map_addr_a;
wire [7:0] map_addr_b;
wire [1:0] map_bank_a;
wire [1:0] map_bank_b;
wire map_conflict;

wire out_valid = valid_meta[META_LATENCY-1];
wire [2:0] out_op = op_meta[META_LATENCY-1];
wire [4:0] out_index = bfly_meta[META_LATENCY-1][4:0];
wire [31:0] summary_signature =
    {transition_mask, first_latency} ^
    {output_count, bubble_count} ^
    {bank_check_count, issue_count};

ntt256_systolic_bank_mapper issue_mapper (
    .inverse(issue_inverse),
    .stage(issue_stage),
    .butterfly_index(issue_bfly),
    .addr_a(map_addr_a),
    .addr_b(map_addr_b),
    .bank_a(map_bank_a),
    .bank_b(map_bank_b),
    .conflict(map_conflict)
);

function [2:0] seq_op;
    input [1:0] op_num;
    begin
        case (op_num)
            2'd0: seq_op = OP_KEM_NTT;
            2'd1: seq_op = OP_DSA_INTT;
            default: seq_op = OP_KEM_INTT;
        endcase
    end
endfunction

function is_inverse_op;
    input [2:0] op;
    begin
        is_inverse_op = (op == OP_KEM_INTT) || (op == OP_DSA_INTT);
    end
endfunction

task advance_expected_output;
    begin
        if (expect_bfly == 7'd127) begin
            expect_bfly <= 7'd0;
            if (expect_stage == 3'd7) begin
                expect_stage <= 3'd0;
                if (expect_op_num != 2'd2) begin
                    expect_op_num <= expect_op_num + 2'd1;
                end
            end else begin
                expect_stage <= expect_stage + 3'd1;
            end
        end else begin
            expect_bfly <= expect_bfly + 7'd1;
        end
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_ISSUE;
        elapsed_cycles <= 16'd0;
        issue_op_num <= 2'd0;
        issue_stage <= 3'd0;
        issue_bfly <= 7'd0;
        expect_op_num <= 2'd0;
        expect_stage <= 3'd0;
        expect_bfly <= 7'd0;
        out_started <= 1'b0;
        last_out_op <= OP_KEM_NTT;
        done <= 1'b0;
        pass <= 1'b0;
        fail <= 1'b0;
        bubble_count <= 16'd0;
        issue_count <= 16'd0;
        output_count <= 16'd0;
        bank_check_count <= 16'd0;
        first_latency <= 16'hffff;
        transition_mask <= 16'd0;
        signature <= 32'h46554c4c;
        for (i = 0; i < META_LATENCY; i = i + 1) begin
            valid_meta[i] <= 1'b0;
            op_num_meta[i] <= 2'd0;
            op_meta[i] <= OP_KEM_NTT;
            stage_meta[i] <= 3'd0;
            bfly_meta[i] <= 7'd0;
            addr_a_meta[i] <= 8'd0;
            addr_b_meta[i] <= 8'd0;
            bank_a_meta[i] <= 2'd0;
            bank_b_meta[i] <= 2'd0;
        end
    end else begin
        if (!done) begin
            elapsed_cycles <= elapsed_cycles + 16'd1;
        end

        valid_meta[0] <= issue_valid;
        op_num_meta[0] <= issue_op_num;
        op_meta[0] <= issue_op;
        stage_meta[0] <= issue_stage;
        bfly_meta[0] <= issue_bfly;
        addr_a_meta[0] <= map_addr_a;
        addr_b_meta[0] <= map_addr_b;
        bank_a_meta[0] <= map_bank_a;
        bank_b_meta[0] <= map_bank_b;
        for (i = 1; i < META_LATENCY; i = i + 1) begin
            valid_meta[i] <= valid_meta[i - 1];
            op_num_meta[i] <= op_num_meta[i - 1];
            op_meta[i] <= op_meta[i - 1];
            stage_meta[i] <= stage_meta[i - 1];
            bfly_meta[i] <= bfly_meta[i - 1];
            addr_a_meta[i] <= addr_a_meta[i - 1];
            addr_b_meta[i] <= addr_b_meta[i - 1];
            bank_a_meta[i] <= bank_a_meta[i - 1];
            bank_b_meta[i] <= bank_b_meta[i - 1];
        end

        if (out_valid) begin
            out_started <= 1'b1;
            if (!out_started) begin
                first_latency <= elapsed_cycles - 16'd1;
            end else begin
                transition_mask[{last_out_op[1:0], out_op[1:0]}] <= 1'b1;
            end
            last_out_op <= out_op;
            output_count <= output_count + 16'd1;
            if ((output_count >= TOTAL_SLOTS) ||
                (out_op != op_meta[META_LATENCY-1]) ||
                (out_index != bfly_meta[META_LATENCY-1][4:0]) ||
                (op_num_meta[META_LATENCY-1] != expect_op_num) ||
                (stage_meta[META_LATENCY-1] != expect_stage) ||
                (bfly_meta[META_LATENCY-1] != expect_bfly)) begin
                fail <= 1'b1;
            end

            advance_expected_output();
        end else if (out_started && (output_count < TOTAL_SLOTS)) begin
            bubble_count <= bubble_count + 16'd1;
            fail <= 1'b1;
        end

        case (state)
            S_ISSUE: begin
                issue_count <= issue_count + 16'd1;
                bank_check_count <= bank_check_count + 16'd1;
                if (map_conflict || (map_bank_a == map_bank_b) ||
                    (map_addr_b <= map_addr_a)) begin
                    fail <= 1'b1;
                end

                if (issue_bfly == 7'd127) begin
                    issue_bfly <= 7'd0;
                    if (issue_stage == 3'd7) begin
                        issue_stage <= 3'd0;
                        if (issue_op_num == 2'd2) begin
                            state <= S_DRAIN;
                        end else begin
                            issue_op_num <= issue_op_num + 2'd1;
                        end
                    end else begin
                        issue_stage <= issue_stage + 3'd1;
                    end
                end else begin
                    issue_bfly <= issue_bfly + 7'd1;
                end
            end

            S_DRAIN: begin
                if (output_count == TOTAL_SLOTS) begin
                    state <= S_DONE;
                end
            end

            S_DONE: begin
                done <= 1'b1;
                signature <= summary_signature;
                pass <= !fail &&
                    (bubble_count == 16'd0) &&
                    (issue_count == TOTAL_SLOTS) &&
                    (output_count == TOTAL_SLOTS) &&
                    (bank_check_count == TOTAL_SLOTS) &&
                    (first_latency == EXPECTED_LATENCY) &&
                    ((transition_mask & EXPECTED_TRANSITIONS) == EXPECTED_TRANSITIONS) &&
                    (summary_signature == EXPECTED_SIGNATURE);
            end

            default: state <= S_DONE;
        endcase
    end
end

endmodule
