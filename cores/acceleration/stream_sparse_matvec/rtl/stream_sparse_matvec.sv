// SPDX-License-Identifier: Apache-2.0
module stream_sparse_matvec #(
    parameter integer DATA_W=16,
    parameter integer VECTOR_LEN=64,
    parameter integer MAX_TERMS=64,
    parameter integer TAG_W=8,
    localparam integer INDEX_W=(VECTOR_LEN<2)?1:$clog2(VECTOR_LEN),
    localparam integer TERM_W=(MAX_TERMS<2)?1:$clog2(MAX_TERMS+1),
    localparam integer GROWTH=$clog2(MAX_TERMS),
    localparam integer ACC_W=2*DATA_W+GROWTH
)(
    input wire clk, rst,
    // Reset begins a sequential full-vector load; reload requests another.
    input wire v_valid,
    output wire v_ready,
    input wire signed [DATA_W-1:0] v_data,
    input wire reload_valid,
    output wire reload_ready,
    // Sparse matrix row entries, any index order, duplicates permitted.
    input wire s_valid,
    output wire s_ready,
    input wire [INDEX_W-1:0] s_index,
    input wire signed [DATA_W-1:0] s_value,
    input wire s_keep, s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire signed [ACC_W-1:0] m_sum,
    output wire [TERM_W-1:0] m_terms,
    output wire m_index_error, m_overflow,
    output wire [TAG_W-1:0] m_tag
);
    generate if(DATA_W<2 || DATA_W>24 || VECTOR_LEN<1 || VECTOR_LEN>4096 ||
                MAX_TERMS<1 || MAX_TERMS>65535 || TAG_W<1 || TAG_W>32) begin : g_invalid
        sparse_matvec_invalid_parameter__see_README invalid_configuration();
    end endgenerate
    localparam [2:0] LOAD=0, INPUT_TERM=1, VECTOR_READ=2, MULTIPLY=3,
                     ACCUMULATE=4, EMIT=5;
    localparam [INDEX_W:0] VECTOR_LIMIT=(INDEX_W+1)'(VECTOR_LEN);
    localparam [TERM_W-1:0] TERM_LIMIT=TERM_W'(MAX_TERMS);
    reg [2:0] state;
    reg [INDEX_W-1:0] load_index, column;
    reg signed [DATA_W-1:0] vector_memory[0:VECTOR_LEN-1];
    reg signed [DATA_W-1:0] vector_sample, coefficient;
    reg signed [2*DATA_W-1:0] product;
    reg signed [ACC_W-1:0] accumulator;
    wire signed [ACC_W-1:0] product_extended=
        {{GROWTH{product[2*DATA_W-1]}},product};
    reg [TERM_W-1:0] terms;
    reg row_open, last_term, index_error, overflow;
    reg [TAG_W-1:0] row_tag;
    wire index_valid={1'b0,s_index}<VECTOR_LIMIT;

    assign v_ready=!rst && state==LOAD;
    assign reload_ready=!rst && state==INPUT_TERM && !row_open;
    // A reload wins only between rows. A request arriving mid-row must wait,
    // without preventing the remainder of that row from being consumed.
    assign s_ready=!rst && state==INPUT_TERM && (row_open || !reload_valid);
    assign m_valid=!rst && state==EMIT;
    assign m_sum=accumulator;
    assign m_terms=terms;
    assign m_index_error=index_error;
    assign m_overflow=overflow;
    assign m_tag=row_tag;

    // Accesses are mutually exclusive, with one synchronous read port.
    // Memory is not reset: an entire vector must load before any row can run.
    always @(posedge clk) begin
        if(!rst && state==LOAD && v_valid)
            vector_memory[load_index]<=v_data;
        if(!rst && state==VECTOR_READ)
            vector_sample<=vector_memory[column];
    end

    always @(posedge clk) begin
        if(rst) begin
            state<=LOAD;
            load_index<=0; column<=0;
            coefficient<=0; product<=0; accumulator<=0;
            terms<=0; row_open<=0; last_term<=0;
            index_error<=0; overflow<=0; row_tag<=0;
        end else case(state)
            LOAD: if(v_valid) begin
                if(load_index==VECTOR_LEN-1) begin
                    load_index<=0;
                    state<=INPUT_TERM;
                end else load_index<=load_index+1'b1;
            end
            INPUT_TERM: begin
                if(reload_valid && reload_ready) begin
                    load_index<=0;
                    state<=LOAD;
                end else if(s_valid && s_ready) begin
                    if(!row_open) row_tag<=s_tag;
                    row_open<=1;
                    if(s_keep && !index_valid) index_error<=1;
                    if(s_keep && terms<TERM_LIMIT) begin
                        terms<=terms+1'b1;
                        if(index_valid) begin
                            coefficient<=s_value;
                            column<=s_index;
                            last_term<=s_last;
                            state<=VECTOR_READ;
                        end else if(s_last) state<=EMIT;
                    end else begin
                        if(s_keep) overflow<=1;
                        if(s_last) state<=EMIT;
                    end
                end
            end
            VECTOR_READ: state<=MULTIPLY;
            MULTIPLY: begin product<=coefficient*vector_sample; state<=ACCUMULATE; end
            ACCUMULATE: begin
                accumulator<=accumulator+product_extended;
                state<=last_term?EMIT:INPUT_TERM;
            end
            EMIT: if(m_ready) begin
                state<=INPUT_TERM;
                accumulator<=0; terms<=0; row_open<=0;
                index_error<=0; overflow<=0; row_tag<=0;
            end
            default: state<=LOAD;
        endcase
    end
endmodule
