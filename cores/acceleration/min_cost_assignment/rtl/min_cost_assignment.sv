// Original ANSCORE contribution, Apache-2.0; see root LICENSE and NOTICE.
`timescale 1ns/1ps
module min_cost_assignment #(
    parameter integer N=8, COST_W=16, TAG_W=8,
    parameter integer INDEX_W=(N>1 ? $clog2(N) : 1),
    parameter integer TOTAL_W=COST_W+$clog2(N),
    parameter integer DUAL_W=COST_W+2*$clog2(N)+3
)(
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire [31:0] s_row, s_column,
    input wire signed [COST_W-1:0] s_cost,
    input wire s_allowed, s_keep, s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg m_keep, m_last,
    output reg [1:0] m_status,
    output reg [TAG_W-1:0] m_tag,
    output reg [INDEX_W-1:0] m_row, m_column,
    output reg signed [COST_W-1:0] m_cost,
    output reg signed [TOTAL_W-1:0] m_total,
    output reg signed [DUAL_W-1:0] m_row_dual, m_column_dual,
    output reg [N-1:0] m_hall_rows, m_hall_columns
);
    localparam integer CW=$clog2(N+1), PW=DUAL_W-1;
    localparam integer AW=(N*N>1 ? $clog2(N*N) : 1);
    localparam [COST_W-1:0] SIGN_MASK={1'b1,{(COST_W-1){1'b0}}};
    localparam [TOTAL_W:0] OFFSET=N*({{TOTAL_W{1'b0}},1'b1} << (COST_W-1));
    localparam [4:0] CLEAR=0, CAPTURE=1, INIT=2, BEGIN_ROW=3,
        CLEAR_TREE=4, MARK=5, READ=6, RELAX=7, SELECT=8,
        UPDATE=9, NEXT=10, AUGMENT=11, INVERT=12,
        OUT_READ=13, OUT_LOAD=14, OUTPUT=15;
    reg [4:0] state;
    reg [COST_W:0] matrix [0:N*N-1]; // {allowed, sign-flipped cost}
    reg [COST_W:0] read_data;
    reg [AW-1:0] clear_addr;
    reg [PW-1:0] u[0:N], negv[0:N], minv[0:N];
    reg [CW-1:0] p[0:N], way[0:N];
    reg used[0:N], finite[0:N];
    reg [INDEX_W-1:0] assignment[0:N-1];
    reg [CW-1:0] root_row, cursor, current_col, current_row;
    reg [CW-1:0] scan_col, best_col, aug_col;
    reg [PW-1:0] delta, best_delta;
    reg best_valid, first, bad;
    reg [TAG_W-1:0] tag;
    reg [N-1:0] tree_rows, tree_columns;
    reg [PW-1:0] shifted_total;
    reg [INDEX_W-1:0] out_row;
    wire [CW-1:0] output_row1={1'b0,out_row}+1'b1;
    wire [CW-1:0] output_col1={1'b0,assignment[out_row]}+1'b1;
    wire [PW-1:0] reduced={{(PW-COST_W){1'b0}},read_data[COST_W-1:0]}
                                  +negv[scan_col]-u[current_row];
    wire improve=read_data[COST_W] && (!finite[scan_col] || reduced<minv[scan_col]);
    wire candidate_valid=finite[scan_col] || read_data[COST_W];
    wire [PW-1:0] candidate=improve ? reduced : minv[scan_col];
    wire signed [PW:0] original_total=$signed({1'b0,shifted_total})
                              -$signed({{(PW-TOTAL_W){1'b0}},OFFSET});
    wire signed [DUAL_W-1:0] original_row_dual=
        $signed({1'b0,u[output_row1]})-$signed({{(DUAL_W-COST_W){1'b0}},SIGN_MASK});
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUTPUT;
    generate if(N<1 || N>32 || COST_W<1 || COST_W>24 || TAG_W<1 || TAG_W>32 ||
           INDEX_W!=(N>1?$clog2(N):1) || TOTAL_W!=COST_W+$clog2(N) ||
           DUAL_W!=COST_W+2*$clog2(N)+3) begin: invalid_parameters
        min_cost_assignment_invalid_parameters__see_README rejected();
    end endgenerate
    always @(posedge clk) begin
        if(rst) begin
            state<=CLEAR; clear_addr<=0; first<=1; bad<=0; tag<=0;
            m_keep<=0; m_last<=0; m_status<=0; m_tag<=0;
            m_row<=0; m_column<=0; m_cost<=0; m_total<=0;
            m_row_dual<=0; m_column_dual<=0; m_hall_rows<=0; m_hall_columns<=0;
        end else case(state)
            CLEAR: begin
                matrix[clear_addr]<=0;
                if(clear_addr==N*N-1) begin state<=CAPTURE; first<=1; bad<=0; end
                else clear_addr<=clear_addr+1'b1;
            end
            CAPTURE: if(s_valid) begin
                if(first) begin tag<=s_tag; first<=0; end
                if(s_keep) begin
                    if(s_row>=N || s_column>=N) bad<=1;
                    else matrix[s_row*N+s_column]<={s_allowed,s_cost^SIGN_MASK};
                end
                if(s_last) begin
                    if(bad || (s_keep && (s_row>=N || s_column>=N))) begin
                        m_keep<=0; m_last<=1; m_status<=1;
                        m_tag<=first?s_tag:tag; m_row<=0; m_column<=0;
                        m_cost<=0; m_total<=0; m_row_dual<=0; m_column_dual<=0;
                        m_hall_rows<=0; m_hall_columns<=0; state<=OUTPUT;
                    end else begin cursor<=0; shifted_total<=0; state<=INIT; end
                end
            end
            INIT: begin
                u[cursor]<=0; negv[cursor]<=0; p[cursor]<=0;
                if(cursor==N) begin root_row<=1; state<=BEGIN_ROW; end
                else cursor<=cursor+1'b1;
            end
            BEGIN_ROW: begin
                p[0]<=root_row; current_col<=0; cursor<=0;
                tree_rows<=0; tree_columns<=0; state<=CLEAR_TREE;
            end
            CLEAR_TREE: begin
                used[cursor]<=0; finite[cursor]<=0; minv[cursor]<=0; way[cursor]<=0;
                if(cursor==N) state<=MARK;
                else cursor<=cursor+1'b1;
            end
            MARK: begin
                used[current_col]<=1; current_row<=p[current_col];
                tree_rows[p[current_col]-1'b1]<=1;
                if(current_col!=0) tree_columns[current_col-1'b1]<=1;
                scan_col<=1; best_valid<=0; best_delta<=0; best_col<=0; state<=READ;
            end
            READ: begin
                if(!used[scan_col]) read_data<=matrix[(current_row-1'b1)*N+scan_col-1'b1];
                state<=RELAX;
            end
            RELAX: begin
                if(!used[scan_col]) begin
                    if(improve) begin minv[scan_col]<=reduced; finite[scan_col]<=1; way[scan_col]<=current_col; end
                    if(candidate_valid && (!best_valid || candidate<best_delta)) begin
                        best_valid<=1; best_delta<=candidate; best_col<=scan_col;
                    end
                end
                if(scan_col==N) state<=SELECT;
                else begin scan_col<=scan_col+1'b1; state<=READ; end
            end
            SELECT: begin
                if(!best_valid) begin
                    m_keep<=0; m_last<=1; m_status<=2; m_tag<=tag;
                    m_row<=0; m_column<=0; m_cost<=0; m_total<=0;
                    m_row_dual<=0; m_column_dual<=0;
                    m_hall_rows<=tree_rows; m_hall_columns<=tree_columns; state<=OUTPUT;
                end else begin
                    delta<=best_delta; shifted_total<=shifted_total+best_delta;
                    cursor<=0; state<=UPDATE;
                end
            end
            UPDATE: begin
                if(used[cursor]) begin
                    u[p[cursor]]<=u[p[cursor]]+delta;
                    if(cursor!=0) negv[cursor]<=negv[cursor]+delta;
                end else if(finite[cursor]) minv[cursor]<=minv[cursor]-delta;
                if(cursor==N) state<=NEXT;
                else cursor<=cursor+1'b1;
            end
            NEXT: begin
                if(p[best_col]==0) begin aug_col<=best_col; state<=AUGMENT; end
                else begin current_col<=best_col; state<=MARK; end
            end
            AUGMENT: begin
                p[aug_col]<=p[way[aug_col]];
                if(way[aug_col]==0) begin
                    if(root_row==N) begin cursor<=1; state<=INVERT; end
                    else begin root_row<=root_row+1'b1; state<=BEGIN_ROW; end
                end else aug_col<=way[aug_col];
            end
            INVERT: begin
                assignment[p[cursor]-1'b1]<=cursor-1'b1;
                if(cursor==N) begin out_row<=0; state<=OUT_READ; end
                else cursor<=cursor+1'b1;
            end
            OUT_READ: begin
                read_data<=matrix[out_row*N+assignment[out_row]]; state<=OUT_LOAD;
            end
            OUT_LOAD: begin
                m_keep<=1; m_last<=(out_row==N-1); m_status<=0; m_tag<=tag;
                m_row<=out_row; m_column<=assignment[out_row]; m_cost<=read_data[COST_W-1:0]^SIGN_MASK;
                m_total<=original_total[TOTAL_W-1:0]; m_row_dual<=original_row_dual;
                m_column_dual<=-$signed({1'b0,negv[output_col1]});
                m_hall_rows<=0; m_hall_columns<=0; state<=OUTPUT;
            end
            OUTPUT: if(m_ready) begin
                if(m_last) begin clear_addr<=0; state<=CLEAR; end
                else begin out_row<=out_row+1'b1; state<=OUT_READ; end
            end
            default: begin state<=CLEAR; clear_addr<=0; end
        endcase
    end
endmodule
