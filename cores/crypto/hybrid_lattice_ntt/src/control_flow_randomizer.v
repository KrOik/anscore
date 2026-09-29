module control_flow_randomizer #(
    parameter ENABLE_DUMMY_SLOTS = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        seed_valid,
    input  wire [31:0] seed,
    input  wire        enable,
    input  wire        in_valid,
    input  wire [2:0]  in_op,
    output wire        in_ready,
    output reg         out_valid,
    output reg  [2:0]  out_op,
    input  wire        out_ready,
    output reg         dummy_slot,
    output reg         error,
    output reg  [2:0]  error_cause,
    output reg  [31:0] lfsr_state,
    output reg  [15:0] input_accepted_count,
    output reg  [15:0] output_issued_count,
    output reg  [15:0] dummy_slot_count,
    output reg  [15:0] invalid_opcode_count,
    output reg  [15:0] transition_count
);

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

localparam [2:0] ERR_NONE           = 3'd0;
localparam [2:0] ERR_INVALID_OPCODE = 3'd1;

localparam [31:0] DEFAULT_SEED = 32'h1ace_b00c;

reg        have_last_output;
reg [2:0]  last_output_op;

wire output_blocked = out_valid && !out_ready;
wire input_valid_opcode = is_valid_op(in_op);
wire can_emit_dummy = !output_blocked && enable && (ENABLE_DUMMY_SLOTS != 0) && lfsr_state[0];
wire can_accept_input = !output_blocked && !can_emit_dummy && in_valid && input_valid_opcode;
wire can_report_invalid = !output_blocked && !can_emit_dummy && in_valid && !input_valid_opcode;
wire advance_cycle = can_emit_dummy || can_accept_input || can_report_invalid;

assign in_ready = !output_blocked && !can_emit_dummy;

function is_valid_op;
    input [2:0] op;
    begin
        is_valid_op = (op == OP_KEM_NTT) || (op == OP_DSA_NTT) ||
                      (op == OP_KEM_INTT) || (op == OP_DSA_INTT);
    end
endfunction

function [31:0] lfsr_next;
    input [31:0] value;
    reg feedback;
    begin
        feedback = value[31] ^ value[21] ^ value[1] ^ value[0];
        lfsr_next = {value[30:0], feedback};
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_valid <= 1'b0;
        out_op <= OP_KEM_NTT;
        dummy_slot <= 1'b0;
        error <= 1'b0;
        error_cause <= ERR_NONE;
        lfsr_state <= DEFAULT_SEED;
        input_accepted_count <= 16'd0;
        output_issued_count <= 16'd0;
        dummy_slot_count <= 16'd0;
        invalid_opcode_count <= 16'd0;
        transition_count <= 16'd0;
        have_last_output <= 1'b0;
        last_output_op <= OP_KEM_NTT;
    end else begin
        if (seed_valid) begin
            lfsr_state <= (seed == 32'd0) ? DEFAULT_SEED : seed;
        end else if (advance_cycle) begin
            lfsr_state <= lfsr_next(lfsr_state);
        end

        if (!output_blocked) begin
            out_valid <= 1'b0;
            dummy_slot <= 1'b0;
            error <= 1'b0;
            error_cause <= ERR_NONE;

            if (can_emit_dummy) begin
                dummy_slot <= 1'b1;
                dummy_slot_count <= dummy_slot_count + 16'd1;
            end else if (can_report_invalid) begin
                error <= 1'b1;
                error_cause <= ERR_INVALID_OPCODE;
                invalid_opcode_count <= invalid_opcode_count + 16'd1;
            end else if (can_accept_input) begin
                out_valid <= 1'b1;
                out_op <= in_op;
                input_accepted_count <= input_accepted_count + 16'd1;
                output_issued_count <= output_issued_count + 16'd1;
                if (have_last_output && (last_output_op != in_op)) begin
                    transition_count <= transition_count + 16'd1;
                end
                have_last_output <= 1'b1;
                last_output_op <= in_op;
            end
        end
    end
end

endmodule
