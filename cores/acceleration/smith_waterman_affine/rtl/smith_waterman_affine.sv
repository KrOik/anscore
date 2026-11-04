// SPDX-License-Identifier: Apache-2.0
// Exact bounded local alignment score, with affine gaps and no traceback.
module smith_waterman_affine #(
    parameter integer CHAR_W=8,
    parameter integer MAX_LEN=32,
    parameter integer MATCH_SCORE=2,
    parameter integer MISMATCH_PENALTY=1,
    parameter integer GAP_OPEN=3,
    parameter integer GAP_EXTEND=1,
    parameter integer TAG_W=8,
    localparam integer COUNT_W=(MAX_LEN<2)?1:$clog2(MAX_LEN+1),
    localparam integer SCORE_W=(MAX_LEN*MATCH_SCORE<2)?1:$clog2(MAX_LEN*MATCH_SCORE+1)
)(
    input wire clk,rst,
    input wire a_valid,output wire a_ready,
    input wire [CHAR_W-1:0] a_char,input wire a_keep,a_last,
    input wire [TAG_W-1:0] a_tag,
    input wire b_valid,output wire b_ready,
    input wire [CHAR_W-1:0] b_char,input wire b_keep,b_last,
    output wire m_valid,input wire m_ready,
    output wire [SCORE_W-1:0] m_score,
    output wire [COUNT_W-1:0] m_a_end,m_b_end,m_a_length,m_b_length,
    output wire [1:0] m_error,
    output wire [TAG_W-1:0] m_tag
);
    generate if(CHAR_W<1 || CHAR_W>16 || MAX_LEN<1 || MAX_LEN>256 ||
        MATCH_SCORE<1 || MATCH_SCORE>255 || MISMATCH_PENALTY<0 || MISMATCH_PENALTY>255 ||
        GAP_OPEN<1 || GAP_OPEN>255 || GAP_EXTEND<1 || GAP_EXTEND>GAP_OPEN ||
        TAG_W<1 || TAG_W>32) begin : g_invalid
        smith_waterman_affine_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    localparam [2:0] COLLECT=0,INITIALIZE=1,ROW=2,FETCH=3,CALCULATE=4,EMIT=5;
    reg [2:0] state;
    reg [CHAR_W-1:0] a_mem[0:MAX_LEN-1],b_mem[0:MAX_LEN-1];
    // Packed H / vertical-gap score, one synchronous read and one write.
    reg [2*SCORE_W-1:0] row_mem[0:MAX_LEN];
    reg [2*SCORE_W-1:0] row_q;
    reg [CHAR_W-1:0] current_a,current_b;
    reg [COUNT_W-1:0] a_length,b_length,i,j,initialize_j;
    reg a_done,b_done,a_overflow,b_overflow,a_first;
    reg [TAG_W-1:0] graph_tag;
    reg [SCORE_W-1:0] left_h,left_gap,diagonal,best_score;
    reg [COUNT_W-1:0] best_a,best_b;
    wire [SCORE_W-1:0] above_h=row_q[SCORE_W-1:0];
    wire [SCORE_W-1:0] above_gap=row_q[2*SCORE_W-1:SCORE_W];

    function automatic [SCORE_W-1:0] subtract_floor_zero;
        input [SCORE_W-1:0] value;
        input integer penalty;
        begin
            // Compare before narrowing a penalty which may exceed SCORE_W.
            if({1'b0,value}>penalty) subtract_floor_zero=value-SCORE_W'(penalty);
            else subtract_floor_zero=0;
        end
    endfunction
    function automatic [SCORE_W-1:0] larger;
        input [SCORE_W-1:0] x,y;
        begin larger=(x>y)?x:y;end
    endfunction
    wire [SCORE_W-1:0] horizontal=larger(subtract_floor_zero(left_h,GAP_OPEN),
        subtract_floor_zero(left_gap,GAP_EXTEND));
    wire [SCORE_W-1:0] vertical=larger(subtract_floor_zero(above_h,GAP_OPEN),
        subtract_floor_zero(above_gap,GAP_EXTEND));
    wire [SCORE_W:0] match_trial={1'b0,diagonal}+(SCORE_W+1)'(MATCH_SCORE);
    wire [SCORE_W-1:0] diagonal_score=(current_a==current_b)?match_trial[SCORE_W-1:0]:
        subtract_floor_zero(diagonal,MISMATCH_PENALTY);
    wire [SCORE_W-1:0] cell_score=larger(diagonal_score,larger(horizontal,vertical));
    assign a_ready=!rst && state==COLLECT && !a_done;
    assign b_ready=!rst && state==COLLECT && !b_done;
    assign m_valid=!rst && state==EMIT;
    assign m_score=best_score;
    // One-based exclusive prefix ends; zero means no positive alignment.
    assign m_a_end=best_a;
    assign m_b_end=best_b;
    assign m_a_length=a_length;
    assign m_b_length=b_length;
    assign m_error={b_overflow,a_overflow};
    assign m_tag=graph_tag;

    always @(posedge clk) begin
        if(!rst) begin
            if(state==COLLECT) begin
                if(a_valid && a_ready && a_keep && a_length<COUNT_W'(MAX_LEN)) a_mem[a_length]<=a_char;
                if(b_valid && b_ready && b_keep && b_length<COUNT_W'(MAX_LEN)) b_mem[b_length]<=b_char;
            end
            if(state==INITIALIZE) row_mem[initialize_j]<=0;
            if(state==FETCH) begin
                current_b<=b_mem[j-1'b1];row_q<=row_mem[j];
            end
            if(state==CALCULATE) row_mem[j]<={vertical,cell_score};
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=COLLECT;a_length<=0;b_length<=0;a_done<=0;b_done<=0;
            a_overflow<=0;b_overflow<=0;a_first<=1;graph_tag<=0;
            i<=0;j<=0;initialize_j<=0;current_a<=0;
            left_h<=0;left_gap<=0;diagonal<=0;best_score<=0;best_a<=0;best_b<=0;
        end else case(state)
            COLLECT: begin
                if(a_valid && a_ready) begin
                    if(a_first) begin graph_tag<=a_tag;a_first<=0;end
                    if(a_keep) begin
                        if(a_length<COUNT_W'(MAX_LEN)) a_length<=a_length+1'b1;
                        else a_overflow<=1;
                    end
                    if(a_last) a_done<=1;
                end
                if(b_valid && b_ready) begin
                    if(b_keep) begin
                        if(b_length<COUNT_W'(MAX_LEN)) b_length<=b_length+1'b1;
                        else b_overflow<=1;
                    end
                    if(b_last) b_done<=1;
                end
                // Both tails and all flags were committed on prior edges.
                if(a_done && b_done) begin
                    if(a_overflow || b_overflow || a_length==0 || b_length==0) state<=EMIT;
                    else begin initialize_j<=0;state<=INITIALIZE;end
                end
            end
            INITIALIZE: begin
                if(initialize_j==b_length) begin i<=1;state<=ROW;end
                else initialize_j<=initialize_j+1'b1;
            end
            ROW: begin
                current_a<=a_mem[i-1'b1];left_h<=0;left_gap<=0;diagonal<=0;j<=1;state<=FETCH;
            end
            FETCH: state<=CALCULATE;
            CALCULATE: begin
                left_h<=cell_score;left_gap<=horizontal;diagonal<=above_h;
                // Strict improvement chooses the earliest A-major/B-minor cell.
                if(cell_score>best_score) begin best_score<=cell_score;best_a<=i;best_b<=j;end
                if(j==b_length) begin
                    if(i==a_length) state<=EMIT;
                    else begin i<=i+1'b1;state<=ROW;end
                end else begin j<=j+1'b1;state<=FETCH;end
            end
            EMIT: if(m_ready) begin
                state<=COLLECT;a_length<=0;b_length<=0;a_done<=0;b_done<=0;
                a_overflow<=0;b_overflow<=0;a_first<=1;graph_tag<=0;
                best_score<=0;best_a<=0;best_b<=0;
            end
            default: state<=COLLECT;
        endcase
    end
endmodule
