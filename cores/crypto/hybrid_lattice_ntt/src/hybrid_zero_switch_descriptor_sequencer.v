module hybrid_zero_switch_descriptor_sequencer #(
    parameter integer MAX_DESCRIPTORS = 4096
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        randomized_mode,
    input  wire [31:0] seed,
    input  wire [15:0] descriptor_count,
    output wire        ready,
    output reg         desc_valid,
    output reg  [2:0]  desc_op,
    input  wire        desc_ready,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [15:0] issued_count,
    output reg  [15:0] accepted_count,
    output reg  [15:0] invalid_bubble_count,
    output reg  [15:0] op_transition_count,
    output reg  [15:0] transition_mask,
    output reg  [15:0] terminal_error_cause
);

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

localparam [15:0] ERR_ZERO_COUNT     = 16'h0001;
localparam [15:0] ERR_INVALID_BUBBLE = 16'h0002;
localparam [15:0] ERR_INVALID_OPCODE = 16'h0004;
localparam [15:0] ERR_TOO_MANY       = 16'h0008;

reg [15:0] target_count;
reg [2:0] last_accepted_op;
reg [31:0] lfsr_state;
reg accepted_started;

assign ready = !busy && !desc_valid && !done;

function [2:0] deterministic_op;
    input [15:0] index;
    begin
        case (index % 16'd17)
            16'd0:  deterministic_op = OP_KEM_NTT;
            16'd1:  deterministic_op = OP_KEM_NTT;
            16'd2:  deterministic_op = OP_DSA_NTT;
            16'd3:  deterministic_op = OP_KEM_NTT;
            16'd4:  deterministic_op = OP_KEM_INTT;
            16'd5:  deterministic_op = OP_KEM_NTT;
            16'd6:  deterministic_op = OP_DSA_INTT;
            16'd7:  deterministic_op = OP_DSA_NTT;
            16'd8:  deterministic_op = OP_DSA_NTT;
            16'd9:  deterministic_op = OP_KEM_INTT;
            16'd10: deterministic_op = OP_DSA_NTT;
            16'd11: deterministic_op = OP_DSA_INTT;
            16'd12: deterministic_op = OP_KEM_INTT;
            16'd13: deterministic_op = OP_KEM_INTT;
            16'd14: deterministic_op = OP_DSA_INTT;
            16'd15: deterministic_op = OP_DSA_INTT;
            default: deterministic_op = OP_KEM_NTT;
        endcase
    end
endfunction

function [31:0] seed_or_default;
    input [31:0] value;
    begin
        seed_or_default = (value == 32'd0) ? 32'h1ace_b00c : value;
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

function [2:0] randomized_op;
    input [31:0] value;
    begin
        randomized_op = {1'b0, value[1:0]};
    end
endfunction

function supported_op;
    input [2:0] op;
    begin
        supported_op = (op == OP_KEM_NTT) || (op == OP_DSA_NTT) ||
            (op == OP_KEM_INTT) || (op == OP_DSA_INTT);
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        target_count <= 16'd0;
        last_accepted_op <= OP_KEM_NTT;
        lfsr_state <= 32'h1ace_b00c;
        accepted_started <= 1'b0;
        desc_valid <= 1'b0;
        desc_op <= OP_KEM_NTT;
        busy <= 1'b0;
        done <= 1'b0;
        error <= 1'b0;
        issued_count <= 16'd0;
        accepted_count <= 16'd0;
        invalid_bubble_count <= 16'd0;
        op_transition_count <= 16'd0;
        transition_mask <= 16'd0;
        terminal_error_cause <= 16'd0;
    end else begin
        done <= 1'b0;

        if (ready && start) begin
            target_count <= descriptor_count;
            last_accepted_op <= OP_KEM_NTT;
            accepted_started <= 1'b0;
            issued_count <= 16'd0;
            accepted_count <= 16'd0;
            invalid_bubble_count <= 16'd0;
            op_transition_count <= 16'd0;
            transition_mask <= 16'd0;
            terminal_error_cause <= 16'd0;
            error <= 1'b0;

            if (descriptor_count == 16'd0) begin
                desc_valid <= 1'b0;
                desc_op <= OP_KEM_NTT;
                busy <= 1'b0;
                done <= 1'b1;
                error <= 1'b1;
                terminal_error_cause <= ERR_ZERO_COUNT;
            end else if (descriptor_count > MAX_DESCRIPTORS[15:0]) begin
                desc_valid <= 1'b0;
                desc_op <= OP_KEM_NTT;
                busy <= 1'b0;
                done <= 1'b1;
                error <= 1'b1;
                terminal_error_cause <= ERR_TOO_MANY;
            end else begin
                desc_valid <= 1'b1;
                desc_op <= randomized_mode
                    ? randomized_op(seed_or_default(seed))
                    : deterministic_op(16'd0);
                lfsr_state <= lfsr_next(seed_or_default(seed));
                issued_count <= 16'd1;
                busy <= 1'b1;
            end
        end else if (busy) begin
            if (desc_valid && desc_ready) begin
                if (!supported_op(desc_op)) begin
                    error <= 1'b1;
                    terminal_error_cause <= terminal_error_cause | ERR_INVALID_OPCODE;
                end

                if (accepted_started) begin
                    transition_mask[{last_accepted_op[1:0], desc_op[1:0]}] <= 1'b1;
                    op_transition_count <= op_transition_count + 16'd1;
                end
                last_accepted_op <= desc_op;
                accepted_started <= 1'b1;
                accepted_count <= accepted_count + 16'd1;

                if ((accepted_count + 16'd1) >= target_count) begin
                    desc_valid <= 1'b0;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    desc_op <= randomized_mode ? randomized_op(lfsr_state)
                                               : deterministic_op(issued_count);
                    lfsr_state <= lfsr_next(lfsr_state);
                    issued_count <= issued_count + 16'd1;
                end
            end else begin
                invalid_bubble_count <= invalid_bubble_count + 16'd1;
                terminal_error_cause <= terminal_error_cause | ERR_INVALID_BUBBLE;
                error <= 1'b1;
            end
        end else if (done && !start) begin
            error <= error;
        end
    end
end

endmodule
