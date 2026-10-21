module ntt256_systolic_issue_pipe (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         in_valid,
    input  wire [2:0]   in_op,
    output wire         in_ready,
    output wire [7:0]   stage_valid,
    output wire [7:0]   stage_mode_dsa,
    output wire [7:0]   stage_inverse,
    output wire [183:0] stage_q_flat,
    output wire [183:0] stage_root_flat,
    output wire [183:0] stage_n_inv_flat,
    output reg          out_valid,
    output reg  [2:0]   out_op,
    output reg  [31:0]  out_signature,
    output reg  [15:0]  accepted_count
);

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

reg [7:0] valid_pipe;
reg [2:0] op_pipe [0:7];
integer i;

assign in_ready = 1'b1;

function is_dsa_op;
    input [2:0] op;
    begin
        is_dsa_op = (op == OP_DSA_NTT) || (op == OP_DSA_INTT);
    end
endfunction

function is_inverse_op;
    input [2:0] op;
    begin
        is_inverse_op = (op == OP_KEM_INTT) || (op == OP_DSA_INTT);
    end
endfunction

function [22:0] q_value;
    input [2:0] op;
    begin
        q_value = is_dsa_op(op) ? 23'd8380417 : 23'd3329;
    end
endfunction

function [22:0] root_value;
    input [2:0] op;
    begin
        root_value = is_dsa_op(op) ? 23'd3073009 : 23'd17;
    end
endfunction

function [22:0] n_inv_value;
    input [2:0] op;
    begin
        n_inv_value = is_dsa_op(op) ? 23'd8347681 : 23'd3316;
    end
endfunction

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

function [31:0] signature_value;
    input [2:0] op;
    input valid;
    reg [31:0] acc;
    integer stage_idx;
    begin
        acc = valid ? (32'h53595350 ^ {29'd0, op}) : 32'd0;
        for (stage_idx = 0; stage_idx < 8; stage_idx = stage_idx + 1) begin
            acc = rotl5(acc) ^
                {9'd0, q_value(op)} ^
                {9'd0, root_value(op)} ^
                {9'd0, n_inv_value(op)} ^
                {20'd0, stage_idx[2:0], is_inverse_op(op), is_dsa_op(op), op};
        end
        signature_value = acc;
    end
endfunction

genvar g;
generate
    for (g = 0; g < 8; g = g + 1) begin : stage_cfg
        assign stage_valid[g] = valid_pipe[g];
        assign stage_mode_dsa[g] = valid_pipe[g] && is_dsa_op(op_pipe[g]);
        assign stage_inverse[g] = valid_pipe[g] && is_inverse_op(op_pipe[g]);
        assign stage_q_flat[(g * 23) +: 23] = valid_pipe[g] ? q_value(op_pipe[g]) : 23'd0;
        assign stage_root_flat[(g * 23) +: 23] = valid_pipe[g] ? root_value(op_pipe[g]) : 23'd0;
        assign stage_n_inv_flat[(g * 23) +: 23] = valid_pipe[g] ? n_inv_value(op_pipe[g]) : 23'd0;
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_pipe <= 8'd0;
        out_valid <= 1'b0;
        out_op <= OP_KEM_NTT;
        out_signature <= 32'd0;
        accepted_count <= 16'd0;
        for (i = 0; i < 8; i = i + 1) begin
            op_pipe[i] <= OP_KEM_NTT;
        end
    end else begin
        out_valid <= valid_pipe[7];
        out_op <= op_pipe[7];
        out_signature <= signature_value(op_pipe[7], valid_pipe[7]);

        valid_pipe <= {valid_pipe[6:0], in_valid && in_ready};
        op_pipe[0] <= in_op;
        for (i = 1; i < 8; i = i + 1) begin
            op_pipe[i] <= op_pipe[i - 1];
        end

        if (in_valid && in_ready) begin
            accepted_count <= accepted_count + 16'd1;
        end
    end
end

endmodule
