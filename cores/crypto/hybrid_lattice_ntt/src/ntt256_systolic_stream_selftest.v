module ntt256_systolic_stream_selftest (
    input  wire        clk,
    input  wire        rst_n,
    output reg         done,
    output reg         pass,
    output reg         fail,
    output reg  [15:0] bubble_count,
    output reg  [15:0] issue_count,
    output reg  [15:0] pair_mask,
    output reg  [31:0] signature
);

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

localparam [2:0] S_ISSUE = 3'd0;
localparam [2:0] S_DRAIN = 3'd1;
localparam [2:0] S_SCAN  = 3'd2;
localparam [2:0] S_DONE  = 3'd3;
localparam [4:0] SEQ_LEN = 5'd17;

reg [2:0] state;
reg [4:0] issue_index;
reg [4:0] out_index;
reg out_started;
reg [2:0] last_out_op;
reg scan_inverse;
reg [2:0] scan_stage;
reg [6:0] scan_index;

wire pipe_valid = (state == S_ISSUE);
wire [2:0] pipe_op = seq_op(issue_index);
wire pipe_ready;
wire [7:0] stage_valid;
wire [7:0] stage_mode_dsa;
wire [7:0] stage_inverse;
wire [183:0] stage_q_flat;
wire [183:0] stage_root_flat;
wire [183:0] stage_n_inv_flat;
wire pipe_out_valid;
wire [2:0] pipe_out_op;
wire [31:0] pipe_out_signature;
wire [15:0] pipe_accepted_count;
wire [7:0] map_addr_a;
wire [7:0] map_addr_b;
wire [1:0] map_bank_a;
wire [1:0] map_bank_b;
wire map_conflict;

ntt256_systolic_issue_pipe issue_pipe (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(pipe_valid),
    .in_op(pipe_op),
    .in_ready(pipe_ready),
    .stage_valid(stage_valid),
    .stage_mode_dsa(stage_mode_dsa),
    .stage_inverse(stage_inverse),
    .stage_q_flat(stage_q_flat),
    .stage_root_flat(stage_root_flat),
    .stage_n_inv_flat(stage_n_inv_flat),
    .out_valid(pipe_out_valid),
    .out_op(pipe_out_op),
    .out_signature(pipe_out_signature),
    .accepted_count(pipe_accepted_count)
);

ntt256_systolic_bank_mapper mapper (
    .inverse(scan_inverse),
    .stage(scan_stage),
    .butterfly_index(scan_index),
    .addr_a(map_addr_a),
    .addr_b(map_addr_b),
    .bank_a(map_bank_a),
    .bank_b(map_bank_b),
    .conflict(map_conflict)
);

function [2:0] seq_op;
    input [4:0] index;
    begin
        case (index)
            4'd0: seq_op = OP_KEM_NTT;
            4'd1: seq_op = OP_KEM_NTT;
            4'd2: seq_op = OP_DSA_NTT;
            4'd3: seq_op = OP_KEM_NTT;
            4'd4: seq_op = OP_KEM_INTT;
            4'd5: seq_op = OP_KEM_NTT;
            4'd6: seq_op = OP_DSA_INTT;
            4'd7: seq_op = OP_DSA_NTT;
            4'd8: seq_op = OP_DSA_NTT;
            4'd9: seq_op = OP_KEM_INTT;
            4'd10: seq_op = OP_DSA_NTT;
            4'd11: seq_op = OP_DSA_INTT;
            4'd12: seq_op = OP_KEM_INTT;
            4'd13: seq_op = OP_KEM_INTT;
            4'd14: seq_op = OP_DSA_INTT;
            4'd15: seq_op = OP_DSA_INTT;
            default: seq_op = OP_KEM_NTT;
        endcase
    end
endfunction

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_ISSUE;
        issue_index <= 4'd0;
        out_index <= 4'd0;
        out_started <= 1'b0;
        last_out_op <= OP_KEM_NTT;
        scan_inverse <= 1'b0;
        scan_stage <= 3'd0;
        scan_index <= 7'd0;
        done <= 1'b0;
        pass <= 1'b0;
        fail <= 1'b0;
        bubble_count <= 16'd0;
        issue_count <= 16'd0;
        pair_mask <= 16'd0;
        signature <= 32'h53595354;
    end else begin
        if (!done && pipe_out_valid) begin
            signature <= rotl5(signature) ^ pipe_out_signature ^ {29'd0, pipe_out_op};
        end

        if (pipe_out_valid) begin
            out_started <= 1'b1;
            if ((out_index >= SEQ_LEN) || (pipe_out_op != seq_op(out_index))) begin
                fail <= 1'b1;
            end else begin
                if (out_started) begin
                    pair_mask[{last_out_op[1:0], pipe_out_op[1:0]}] <= 1'b1;
                end
                last_out_op <= pipe_out_op;
                out_index <= out_index + 4'd1;
            end
        end else if (out_started && (out_index < SEQ_LEN)) begin
            bubble_count <= bubble_count + 16'd1;
            fail <= 1'b1;
        end

        case (state)
            S_ISSUE: begin
                if (!pipe_ready) begin
                    fail <= 1'b1;
                end else begin
                    issue_count <= issue_count + 16'd1;
                end

                if (issue_index == (SEQ_LEN - 1'b1)) begin
                    state <= S_DRAIN;
                end else begin
                    issue_index <= issue_index + 4'd1;
                end
            end

            S_DRAIN: begin
                if (out_index == SEQ_LEN) begin
                    state <= S_SCAN;
                end
            end

            S_SCAN: begin
                signature <= rotl5(signature) ^
                    {24'd0, map_addr_a} ^
                    {24'd0, map_addr_b} ^
                    {28'd0, map_bank_a, map_bank_b} ^
                    {27'd0, scan_inverse, scan_stage};

                if (map_conflict || (map_addr_b <= map_addr_a) ||
                    (map_bank_a == map_bank_b)) begin
                    fail <= 1'b1;
                end

                if (scan_index == 7'd127) begin
                    scan_index <= 7'd0;
                    if (scan_stage == 3'd7) begin
                        scan_stage <= 3'd0;
                        if (scan_inverse) begin
                            state <= S_DONE;
                        end else begin
                            scan_inverse <= 1'b1;
                        end
                    end else begin
                        scan_stage <= scan_stage + 3'd1;
                    end
                end else begin
                    scan_index <= scan_index + 7'd1;
                end
            end

            S_DONE: begin
                done <= 1'b1;
                pass <= !fail && (bubble_count == 16'd0) &&
                    (issue_count == {11'd0, SEQ_LEN}) &&
                    (pipe_accepted_count == {11'd0, SEQ_LEN}) &&
                    (pair_mask == 16'hffff);
            end

            default: state <= S_DONE;
        endcase
    end
end

endmodule
