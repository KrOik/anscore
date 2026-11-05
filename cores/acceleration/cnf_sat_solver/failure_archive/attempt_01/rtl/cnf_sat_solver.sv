// SPDX-License-Identifier: Apache-2.0
// Exact bounded CNF SAT by serial unit propagation and chronological DPLL.
module cnf_sat_solver #(
    parameter integer MAX_VARS = 8,
    parameter integer MAX_CLAUSES = 16,
    parameter integer TAG_W = 8
) (
    input  wire clk,
    input  wire rst,
    input  wire c_valid,
    output wire c_ready,
    input  wire [31:0] c_num_vars,
    input  wire [31:0] c_num_clauses,
    input  wire c_error,
    input  wire [(TAG_W > 0 ? TAG_W : 1)-1:0] c_tag,
    input  wire s_valid,
    output wire s_ready,
    input  wire [(MAX_VARS > 0 ? MAX_VARS : 1)-1:0] s_positive,
    input  wire [(MAX_VARS > 0 ? MAX_VARS : 1)-1:0] s_negative,
    input  wire s_last,
    input  wire s_error,
    output wire m_valid,
    input  wire m_ready,
    output reg m_sat,
    output reg [(MAX_VARS > 0 ? MAX_VARS : 1)-1:0] m_assignment,
    output reg [5:0] m_error,
    output reg [(TAG_W > 0 ? TAG_W : 1)-1:0] m_tag
);
    localparam integer V = MAX_VARS > 0 ? MAX_VARS : 1;
    localparam integer C = MAX_CLAUSES > 0 ? MAX_CLAUSES : 1;
    localparam integer CW = $clog2(C+1) > 0 ? $clog2(C+1) : 1;
    localparam integer DW = $clog2(V+1) > 0 ? $clog2(V+1) : 1;
    localparam [3:0] IDLE=0, LOAD=1, SCAN_START=2, CLAUSE_READ=3,
        CLAUSE_EVAL=4, SCAN_DONE=5, DECIDE=6, POP=7, RESTORE=8,
        RESULT=9;

    generate
        if (MAX_VARS < 1 || MAX_VARS > 16 ||
            MAX_CLAUSES < 1 || MAX_CLAUSES > 64 ||
            TAG_W < 1 || TAG_W > 32) begin : invalid_parameters
            initial $fatal(1, "CNF_SAT_PARAMETER_REJECT");
        end
    endgenerate

    reg [3:0] state;
    reg [CW-1:0] clause_count, load_count, clause_index;
    reg [DW-1:0] pending_depth;
    reg [V-1:0] variable_mask, assigned_mask, value_mask, unresolved_mask;
    reg all_satisfied;
    reg [5:0] input_errors;

    // A single synchronous port per bank. Neither payload nor read data reset.
    reg [2*V-1:0] clause_mem [0:C-1];
    reg [2*V-1:0] pending_mem [0:V-1];
    reg [2*V-1:0] clause_q, pending_q;

    assign c_ready = !rst && state == IDLE;
    assign s_ready = !rst && state == LOAD;
    assign m_valid = !rst && state == RESULT;
    wire command_take = c_valid && c_ready;
    wire row_take = s_valid && s_ready;
    wire final_row = load_count == clause_count-1'b1;
    wire [5:0] command_errors = {c_error, 3'b000,
        (c_num_clauses > MAX_CLAUSES), (c_num_vars > MAX_VARS)};
    wire [5:0] row_errors = input_errors | {s_error,
        (final_row && !s_last), (!final_row && s_last),
        (|((s_positive | s_negative) & ~variable_mask)), 2'b00};

    wire clause_we = !rst && row_take;
    wire clause_re = !rst && state == CLAUSE_READ;
    wire pending_we = !rst && state == DECIDE;
    wire pending_re = !rst && state == POP && pending_depth != 0;
    wire [V-1:0] positive = clause_q[2*V-1:V];
    wire [V-1:0] negative = clause_q[V-1:0];
    wire clause_satisfied = |(positive & negative) ||
        |(positive & value_mask & assigned_mask) ||
        |(negative & ~value_mask & assigned_mask);
    wire [V-1:0] unassigned = (positive | negative) & ~assigned_mask;
    wire clause_unit = unassigned != 0 &&
        (unassigned & (unassigned-1'b1)) == 0;

    // A full pass accumulates only variables in still-unsatisfied clauses.
    reg [V-1:0] branch_bit;
    integer bit_index;
    always @* begin
        branch_bit = 0;
        for (bit_index=0; bit_index<V; bit_index=bit_index+1)
            if (unresolved_mask[bit_index] && branch_bit == 0)
                branch_bit[bit_index] = 1'b1;
    end

    always @(posedge clk) begin
        if (clause_we)
            clause_mem[load_count] <= {s_positive, s_negative};
        else if (clause_re)
            clause_q <= clause_mem[clause_index];
        if (pending_we)
            pending_mem[pending_depth] <=
                {assigned_mask | branch_bit, value_mask | branch_bit};
        else if (pending_re)
            pending_q <= pending_mem[pending_depth-1'b1];
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            clause_count <= 0;
            load_count <= 0;
            clause_index <= 0;
            pending_depth <= 0;
            variable_mask <= 0;
            assigned_mask <= 0;
            value_mask <= 0;
            unresolved_mask <= 0;
            all_satisfied <= 0;
            input_errors <= 0;
            m_sat <= 0;
            m_assignment <= 0;
            m_error <= 0;
            m_tag <= 0;
        end else begin
            case (state)
                IDLE: if (command_take) begin
                    m_tag <= c_tag;
                    m_sat <= 0;
                    m_assignment <= 0;
                    m_error <= command_errors;
                    input_errors <= command_errors;
                    load_count <= 0;
                    pending_depth <= 0;
                    assigned_mask <= 0;
                    value_mask <= 0;
                    unresolved_mask <= 0;
                    if (command_errors[1:0] != 0) begin
                        variable_mask <= 0;
                        clause_count <= 0;
                        state <= RESULT;
                    end else begin
                        variable_mask <= {V{1'b1}} >> (V-c_num_vars);
                        clause_count <= c_num_clauses[CW-1:0];
                        if (c_num_clauses == 0) begin
                            m_sat <= !c_error;
                            state <= RESULT;
                        end else state <= LOAD;
                    end
                end
                LOAD: if (row_take) begin
                    input_errors <= row_errors;
                    if (s_last || final_row) begin
                        m_error <= row_errors;
                        if (row_errors != 0) state <= RESULT;
                        else state <= SCAN_START;
                    end else load_count <= load_count+1'b1;
                end
                SCAN_START: begin
                    clause_index <= 0;
                    all_satisfied <= 1;
                    unresolved_mask <= 0;
                    state <= CLAUSE_READ;
                end
                CLAUSE_READ: state <= CLAUSE_EVAL;
                CLAUSE_EVAL: begin
                    if (!clause_satisfied && unassigned == 0)
                        state <= POP;
                    else if (!clause_satisfied && clause_unit) begin
                        assigned_mask <= assigned_mask | unassigned;
                        value_mask <= (value_mask & ~unassigned) |
                            (positive & unassigned);
                        state <= SCAN_START;
                    end else begin
                        if (!clause_satisfied) begin
                            all_satisfied <= 0;
                            unresolved_mask <= unresolved_mask | unassigned;
                        end
                        if (clause_index == clause_count-1'b1)
                            state <= SCAN_DONE;
                        else begin
                            clause_index <= clause_index+1'b1;
                            state <= CLAUSE_READ;
                        end
                    end
                end
                SCAN_DONE: begin
                    if (all_satisfied) begin
                        m_sat <= 1;
                        m_assignment <= value_mask & variable_mask;
                        m_error <= 0;
                        state <= RESULT;
                    end else state <= DECIDE;
                end
                DECIDE: begin
                    // The pending true child owns a complete assignment image.
                    pending_depth <= pending_depth+1'b1;
                    assigned_mask <= assigned_mask | branch_bit;
                    value_mask <= value_mask & ~branch_bit;
                    state <= SCAN_START;
                end
                POP: begin
                    if (pending_depth == 0) begin
                        m_sat <= 0;
                        m_assignment <= 0;
                        m_error <= 0;
                        state <= RESULT;
                    end else begin
                        pending_depth <= pending_depth-1'b1;
                        state <= RESTORE;
                    end
                end
                RESTORE: begin
                    assigned_mask <= pending_q[2*V-1:V];
                    value_mask <= pending_q[V-1:0];
                    state <= SCAN_START;
                end
                RESULT: if (m_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
