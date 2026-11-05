// SPDX-License-Identifier: Apache-2.0
// Positive-weight undirected terminal-subset Steiner DP. SOURCE_ONLY / NOT_RUN.
`timescale 1ns/1ps
module exact_undirected_steiner_tree #(
    parameter NUM_NODES=8, MAX_TERMINALS=4, WEIGHT_W=16, TAG_W=8
)(
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire s_present, input wire [WEIGHT_W-1:0] s_weight,
    input wire s_last, input wire [NUM_NODES-1:0] s_terminals,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire m_summary,
    output wire [((NUM_NODES<2)?1:$clog2(NUM_NODES))-1:0] m_u,m_v,
    output wire [WEIGHT_W-1:0] m_weight,
    output wire [WEIGHT_W+$clog2(NUM_NODES)-1:0] m_total_cost,
    output wire [$clog2(NUM_NODES+1)-1:0] m_selected_count,
    output wire [NUM_NODES-1:0] m_vertices,m_terminals,
    output wire m_feasible, output wire [3:0] m_error,
    output wire [TAG_W-1:0] m_tag
);
    // Safe internal shapes leave illegal-domain diagnostics to named instances.
    localparam N=(NUM_NODES>=2 && NUM_NODES<=16)?NUM_NODES:2;
    localparam K=(MAX_TERMINALS>=1 && MAX_TERMINALS<=6 && MAX_TERMINALS<=N)?MAX_TERMINALS:1;
    localparam W=(WEIGHT_W>=1 && WEIGHT_W<=24)?WEIGHT_W:1;
    localparam T=(TAG_W>=1 && TAG_W<=32)?TAG_W:1;
    localparam IW=$clog2(N), CW=$clog2(N+1), SW=W+IW;
    localparam E=N*(N-1)/2, EW=(E<2)?1:$clog2(E), ECW=$clog2(E+1);
    localparam ROWS=N*(1<<K), DAW=$clog2(ROWS), MAW=$clog2(N*N);
    localparam RW=1+2+IW+K+SW, SPW=$clog2(K+1);
    localparam [1:0] BASE=0, MERGE=1, MOVE=2;
    generate
        if(NUM_NODES<2 || NUM_NODES>16) begin:bad_n
            exact_undirected_steiner_tree_invalid_NUM_NODES__see_README invalid();
        end
        if(MAX_TERMINALS<1 || MAX_TERMINALS>6 || MAX_TERMINALS>NUM_NODES) begin:bad_k
            exact_undirected_steiner_tree_invalid_MAX_TERMINALS__see_README invalid();
        end
        if(WEIGHT_W<1 || WEIGHT_W>24) begin:bad_w
            exact_undirected_steiner_tree_invalid_WEIGHT_W__see_README invalid();
        end
        if(TAG_W<1 || TAG_W>32) begin:bad_t
            exact_undirected_steiner_tree_invalid_TAG_W__see_README invalid();
        end
    endgenerate

    function automatic [RW-1:0] row_pack(
        input valid_bit,input [1:0] kind,input [IW-1:0] parent,
        input [K-1:0] split,input [SW-1:0] score);
        row_pack={valid_bit,kind,parent,split,score};
    endfunction
    function automatic row_valid(input [RW-1:0] row);row_valid=row[RW-1];endfunction
    function automatic [1:0] row_kind(input [RW-1:0] row);row_kind=row[RW-2 -:2];endfunction
    function automatic [IW-1:0] row_parent(input [RW-1:0] row);row_parent=row[SW+K +:IW];endfunction
    function automatic [K-1:0] row_split(input [RW-1:0] row);row_split=row[SW +:K];endfunction
    function automatic [SW-1:0] row_score(input [RW-1:0] row);row_score=row[SW-1:0];endfunction
    function automatic [DAW-1:0] dp_index(input [K-1:0] mask,input [IW-1:0] vertex);
        dp_index=mask*N+vertex; // N is an elaboration constant; exact N stride.
    endfunction
    function automatic [MAW-1:0] matrix_index(input [IW-1:0] u,input [IW-1:0] v);
        matrix_index=u*N+v;
    endfunction
    function automatic [EW-1:0] edge_index(input [IW-1:0] a,input [IW-1:0] b);
        reg [IW-1:0] low_id,high_id;
        integer j;
        begin
            low_id=(a<b)?a:b;high_id=(a<b)?b:a;edge_index=0;
            // Each row base is constant; no runtime u*u arithmetic is required.
            for(j=0;j<N;j=j+1)
                if(low_id==j)edge_index=j*(2*N-j-1)/2+high_id-j-1;
        end
    endfunction

    localparam [5:0] CAPTURE=0,WRITE_A=1,WRITE_B=2,TERM_BEGIN=3,TERM_SCAN=4,TERM_DONE=5,
        INIT_ROW=6,BEST_READ=7,BEST_TAKE=8,SPLIT_SCAN=9,LEFT_READ=10,LEFT_TAKE=11,
        RIGHT_READ=12,RIGHT_TAKE=13,BEST_WRITE=14,MIN_BEGIN=15,MIN_READ=16,
        MIN_TAKE=17,MIN_DONE=18,RELAX_SCAN=19,EDGE_READ=20,EDGE_TAKE=21,
        DST_READ=22,DST_TAKE=23,DST_WRITE=24,RELAX_NEXT=25,MASK_DONE=26,
        ROOT_BEGIN=27,ROOT_READ=28,ROOT_TAKE=29,ROOT_DONE=30,TRACE_READ=31,
        TRACE_TAKE=32,TRACE_EDGE_READ=33,TRACE_EDGE_TAKE=34,TRACE_PARENT_READ=35,
        TRACE_PARENT_TAKE=36,COUNT_BEGIN=37,COUNT_SCAN=38,EMIT_BEGIN=39,
        EMIT_SCAN=40,EMIT_READ=41,EMIT_TAKE=42,OUT_EDGE=43,EMIT_NEXT=44,OUT_SUM=45;
    reg [5:0] state;
    reg [N-1:0] terminal_mask,vertices,settled;
    reg [T-1:0] tag_reg;
    reg [3:0] error_flags;
    reg feasible;
    reg [SW-1:0] total_cost;
    reg [CW-1:0] selected_count,terminal_count;
    reg [IW-1:0] terminals[0:K-1];
    // Packed combinational view avoids array-sensitivity diagnostics in Icarus.
    wire [K*IW-1:0] terminal_words;
    genvar terminal_id;
    generate for(terminal_id=0;terminal_id<K;terminal_id=terminal_id+1)begin:terminal_view
        assign terminal_words[terminal_id*IW +: IW]=terminals[terminal_id];
    end endgenerate
    reg [IW-1:0] in_u,in_v,vertex,source_vertex,target_vertex,min_vertex;
    reg [IW-1:0] emit_u,emit_v,out_u,out_v;
    reg [ECW-1:0] input_count;
    reg [EW-1:0] bitmap_cursor;
    reg [W:0] captured_edge;
    reg [W-1:0] edge_weight,out_weight;
    reg [K-1:0] mask,full_mask,split,trace_mask;
    reg [IW-1:0] trace_vertex,trace_parent;
    reg [RW-1:0] best_row,left_row,min_row,source_row,write_row,trace_row;
    reg min_found;
    reg [K+IW-1:0] pending[0:K-1];
    reg [SPW-1:0] pending_count;
    reg [7:0] trace_work;
    reg [E-1:0] edge_bitmap;
    reg [RW-1:0] dp_mem[0:ROWS-1],dp_q;
    reg [W:0] matrix_mem[0:N*N-1],matrix_q;
    reg dp_re,dp_we,matrix_re,matrix_we;
    reg [DAW-1:0] dp_addr;
    reg [MAW-1:0] matrix_addr;
    reg [RW-1:0] dp_din;
    reg [W:0] matrix_din;
    reg [SW:0] add_a,add_b;
    wire [SW:0] candidate_sum=add_a+add_b;
    reg [SW-1:0] compare_a,compare_b;
    wire score_less=(compare_a<compare_b);
    reg [IW-1:0] singleton_vertex;
    integer term_bit;
    always @* begin
        singleton_vertex=0;
        for(term_bit=0;term_bit<K;term_bit=term_bit+1)
            if(mask[term_bit])singleton_vertex=terminal_words[term_bit*IW +: IW];
    end
    wire mask_singleton=(mask!=0)&&((mask&(mask-1'b1))==0);
    wire [K-1:0] other_split=mask^split;
    wire [K-1:0] traced_split=row_split(dp_q);
    wire [IW-1:0] traced_parent=row_parent(dp_q);
    reg [IW-1:0] trace_terminal;
    integer trace_bit;
    always @* begin
        trace_terminal=0;
        for(trace_bit=0;trace_bit<K;trace_bit=trace_bit+1)
            if(trace_mask[trace_bit])trace_terminal=terminal_words[trace_bit*IW +: IW];
    end
    always @* begin
        compare_a=0;compare_b=0;
        case(state)
            RIGHT_TAKE:begin compare_a=candidate_sum[SW-1:0];compare_b=row_score(best_row);end
            DST_TAKE:begin compare_a=candidate_sum[SW-1:0];compare_b=row_score(dp_q);end
            MIN_TAKE,ROOT_TAKE:begin compare_a=row_score(dp_q);compare_b=row_score(min_row);end
            TRACE_PARENT_TAKE:begin compare_a=row_score(dp_q);compare_b=row_score(trace_row);end
            default:begin end
        endcase
    end

    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && (state==OUT_EDGE || state==OUT_SUM);
    assign m_summary=state==OUT_SUM;
    assign m_u=(state==OUT_EDGE)?out_u:0;
    assign m_v=(state==OUT_EDGE)?out_v:0;
    assign m_weight=(state==OUT_EDGE)?out_weight:0;
    assign m_total_cost=total_cost;
    assign m_selected_count=selected_count;
    assign m_vertices=vertices;
    assign m_terminals=terminal_mask;
    assign m_feasible=feasible;
    assign m_error=error_flags;
    assign m_tag=tag_reg;

    // Read and write share one address/port in each bank. Reset masks requests.
    always @* begin
        dp_re=0;dp_we=0;dp_addr=0;dp_din=0;
        matrix_re=0;matrix_we=0;matrix_addr=0;matrix_din=captured_edge;
        add_a=0;add_b=0;
        if(!rst)case(state)
            WRITE_A:begin matrix_we=1;matrix_addr=matrix_index(in_u,in_v);end
            WRITE_B:begin matrix_we=1;matrix_addr=matrix_index(in_v,in_u);end
            INIT_ROW:begin
                dp_we=1;dp_addr=dp_index(mask,vertex);
                dp_din=row_pack(mask_singleton && vertex==singleton_vertex,BASE,0,0,0);
            end
            BEST_READ:begin dp_re=1;dp_addr=dp_index(mask,vertex);end
            LEFT_READ:begin dp_re=1;dp_addr=dp_index(split,vertex);end
            RIGHT_READ:begin dp_re=1;dp_addr=dp_index(other_split,vertex);end
            RIGHT_TAKE:begin add_a={1'b0,row_score(left_row)};add_b={1'b0,row_score(dp_q)};end
            BEST_WRITE:begin dp_we=1;dp_addr=dp_index(mask,vertex);dp_din=best_row;end
            MIN_READ,ROOT_READ:begin dp_re=1;dp_addr=dp_index(mask,vertex);end
            EDGE_READ:begin matrix_re=1;matrix_addr=matrix_index(source_vertex,target_vertex);end
            DST_READ:begin dp_re=1;dp_addr=dp_index(mask,target_vertex);end
            DST_TAKE:begin add_a={1'b0,row_score(source_row)};add_b={{(SW+1-W){1'b0}},edge_weight};end
            DST_WRITE:begin dp_we=1;dp_addr=dp_index(mask,target_vertex);dp_din=write_row;end
            TRACE_READ:begin dp_re=1;dp_addr=dp_index(trace_mask,trace_vertex);end
            TRACE_EDGE_READ:begin matrix_re=1;matrix_addr=matrix_index(trace_vertex,trace_parent);end
            TRACE_PARENT_READ:begin dp_re=1;dp_addr=dp_index(trace_mask,trace_parent);end
            TRACE_PARENT_TAKE:begin add_a={1'b0,row_score(dp_q)};add_b={{(SW+1-W){1'b0}},edge_weight};end
            EMIT_READ:begin matrix_re=1;matrix_addr=matrix_index(emit_u,emit_v);end
            default:begin end
        endcase
    end
    always @(posedge clk) begin
        if(dp_we)dp_mem[dp_addr]<=dp_din;
        else if(dp_re)dp_q<=dp_mem[dp_addr];
        if(matrix_we)matrix_mem[matrix_addr]<=matrix_din;
        else if(matrix_re)matrix_q<=matrix_mem[matrix_addr];
    end
    task automatic trace_error;
        begin
            error_flags[3]<=1;feasible<=0;total_cost<=0;
            selected_count<=0;vertices<=0;state<=OUT_SUM;
        end
    endtask
    task automatic finish_trace_task;
        begin
            if(pending_count!=0)begin
                {trace_mask,trace_vertex}<=pending[pending_count-1'b1];
                pending_count<=pending_count-1'b1;state<=TRACE_READ;
            end else state<=COUNT_BEGIN;
        end
    endtask
    integer bit_id;
    always @(posedge clk) begin
        if(rst)begin
            state<=CAPTURE;input_count<=0;in_u<=0;in_v<=1;
            feasible<=0;error_flags<=0;selected_count<=0;vertices<=0;
            terminal_mask<=0;tag_reg<=0;total_cost<=0;pending_count<=0;trace_work<=0;
            settled<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                captured_edge<={s_present,s_weight};
                if(input_count==0)begin
                    terminal_mask<=s_terminals;tag_reg<=s_tag;
                    error_flags<={1'b0,(s_last!=(input_count==E-1)),(s_present&&s_weight==0),1'b0};
                    feasible<=0;total_cost<=0;selected_count<=0;vertices<=0;
                end else begin
                    if(s_present && s_weight==0)error_flags[1]<=1;
                    if(s_last!=(input_count==E-1))error_flags[2]<=1;
                end
                state<=WRITE_A;
            end
            WRITE_A:state<=WRITE_B;
            WRITE_B:begin
                if(input_count==E-1)state<=TERM_BEGIN;
                else begin
                    input_count<=input_count+1'b1;
                    if(in_v==N-1)begin in_u<=in_u+1'b1;in_v<=in_u+2;end
                    else in_v<=in_v+1'b1;
                    state<=CAPTURE;
                end
            end
            TERM_BEGIN:begin terminal_count<=0;vertex<=0;state<=TERM_SCAN;end
            TERM_SCAN:begin
                if(terminal_mask[vertex])begin
                    if(terminal_count<K)terminals[terminal_count]<=vertex;
                    else error_flags[0]<=1;
                    terminal_count<=terminal_count+1'b1;
                end
                if(vertex==N-1)state<=TERM_DONE;else vertex<=vertex+1'b1;
            end
            TERM_DONE:begin
                if(terminal_count==0 || terminal_count>K)begin error_flags[0]<=1;state<=OUT_SUM;end
                else if(error_flags!=0)state<=OUT_SUM;
                else if(terminal_count==1)begin feasible<=1;vertices<=terminal_mask;state<=OUT_SUM;end
                else begin
                    for(bit_id=0;bit_id<K;bit_id=bit_id+1)full_mask[bit_id]<=(bit_id<terminal_count);
                    mask<=1;vertex<=0;settled<=0;state<=INIT_ROW;
                end
            end
            INIT_ROW:begin
                if(vertex==N-1)begin vertex<=0;state<=BEST_READ;end
                else vertex<=vertex+1'b1;
            end
            BEST_READ:state<=BEST_TAKE;
            BEST_TAKE:begin best_row<=dp_q;split<=1;state<=SPLIT_SCAN;end
            SPLIT_SCAN:begin
                if(split>=mask)state<=BEST_WRITE;
                else if((split&mask)==split && split<other_split)state<=LEFT_READ;
                else split<=split+1'b1;
            end
            LEFT_READ:state<=LEFT_TAKE;
            LEFT_TAKE:begin left_row<=dp_q;state<=RIGHT_READ;end
            RIGHT_READ:state<=RIGHT_TAKE;
            RIGHT_TAKE:begin
                if(row_valid(left_row) && row_valid(dp_q) && !candidate_sum[SW] &&
                   (!row_valid(best_row) || score_less))
                    best_row<=row_pack(1'b1,MERGE,0,split,candidate_sum[SW-1:0]);
                split<=split+1'b1;state<=SPLIT_SCAN;
            end
            BEST_WRITE:begin
                if(vertex==N-1)state<=MIN_BEGIN;
                else begin vertex<=vertex+1'b1;state<=BEST_READ;end
            end
            MIN_BEGIN:begin vertex<=0;min_found<=0;state<=MIN_READ;end
            MIN_READ:state<=MIN_TAKE;
            MIN_TAKE:begin
                if(!settled[vertex] && row_valid(dp_q) &&
                   (!min_found || score_less))begin
                    min_found<=1;min_row<=dp_q;min_vertex<=vertex;
                end
                if(vertex==N-1)state<=MIN_DONE;
                else begin vertex<=vertex+1'b1;state<=MIN_READ;end
            end
            MIN_DONE:begin
                if(!min_found)state<=MASK_DONE;
                else begin
                    settled[min_vertex]<=1;source_vertex<=min_vertex;source_row<=min_row;
                    target_vertex<=0;state<=RELAX_SCAN;
                end
            end
            RELAX_SCAN:begin
                if(settled[target_vertex])state<=RELAX_NEXT;
                else state<=EDGE_READ;
            end
            EDGE_READ:state<=EDGE_TAKE;
            EDGE_TAKE:begin
                if(matrix_q[W])begin edge_weight<=matrix_q[W-1:0];state<=DST_READ;end
                else state<=RELAX_NEXT;
            end
            DST_READ:state<=DST_TAKE;
            DST_TAKE:begin
                if(!candidate_sum[SW] && (!row_valid(dp_q) || score_less))begin
                    write_row<=row_pack(1'b1,MOVE,source_vertex,0,candidate_sum[SW-1:0]);state<=DST_WRITE;
                end else state<=RELAX_NEXT;
            end
            DST_WRITE:state<=RELAX_NEXT;
            RELAX_NEXT:begin
                if(target_vertex==N-1)state<=MIN_BEGIN;
                else begin target_vertex<=target_vertex+1'b1;state<=RELAX_SCAN;end
            end
            MASK_DONE:begin
                if(mask==full_mask)state<=ROOT_BEGIN;
                else begin mask<=mask+1'b1;vertex<=0;settled<=0;state<=INIT_ROW;end
            end
            ROOT_BEGIN:begin vertex<=0;min_found<=0;state<=ROOT_READ;end
            ROOT_READ:state<=ROOT_TAKE;
            ROOT_TAKE:begin
                if(row_valid(dp_q) && (!min_found || score_less))begin
                    min_found<=1;min_row<=dp_q;min_vertex<=vertex;
                end
                if(vertex==N-1)state<=ROOT_DONE;
                else begin vertex<=vertex+1'b1;state<=ROOT_READ;end
            end
            ROOT_DONE:begin
                if(!min_found)state<=OUT_SUM;
                else begin
                    feasible<=1;total_cost<=row_score(min_row);edge_bitmap<=0;vertices<=0;
                    trace_mask<=full_mask;trace_vertex<=min_vertex;pending_count<=0;
                    trace_work<=0;state<=TRACE_READ;
                end
            end
            TRACE_READ:state<=TRACE_TAKE;
            TRACE_TAKE:begin
                trace_work<=trace_work+1'b1;
                if(trace_work>=176 || trace_mask==0 || !row_valid(dp_q))trace_error();
                else case(row_kind(dp_q))
                    BASE:begin
                        if((trace_mask&(trace_mask-1'b1))!=0 || trace_vertex!=trace_terminal || row_score(dp_q)!=0)trace_error();
                        else begin vertices[trace_vertex]<=1;finish_trace_task();end
                    end
                    MERGE:begin
                        if(traced_split==0 || traced_split==trace_mask || (traced_split&trace_mask)!=traced_split || pending_count>=K)trace_error();
                        else begin
                            pending[pending_count]<={trace_mask^traced_split,trace_vertex};
                            pending_count<=pending_count+1'b1;trace_mask<=traced_split;state<=TRACE_READ;
                        end
                    end
                    MOVE:begin
                        if(traced_parent>=N || traced_parent==trace_vertex)trace_error();
                        else begin trace_parent<=traced_parent;trace_row<=dp_q;state<=TRACE_EDGE_READ;end
                    end
                    default:trace_error();
                endcase
            end
            TRACE_EDGE_READ:state<=TRACE_EDGE_TAKE;
            TRACE_EDGE_TAKE:begin
                if(!matrix_q[W] || matrix_q[W-1:0]==0)trace_error();
                else begin edge_weight<=matrix_q[W-1:0];state<=TRACE_PARENT_READ;end
            end
            TRACE_PARENT_READ:state<=TRACE_PARENT_TAKE;
            TRACE_PARENT_TAKE:begin
                if(!row_valid(dp_q) || candidate_sum[SW] || candidate_sum[SW-1:0]!=row_score(trace_row) || !score_less)trace_error();
                else begin
                    edge_bitmap[edge_index(trace_vertex,trace_parent)]<=1;
                    vertices[trace_vertex]<=1;vertices[trace_parent]<=1;
                    trace_vertex<=trace_parent;state<=TRACE_READ;
                end
            end
            COUNT_BEGIN:begin selected_count<=0;bitmap_cursor<=0;state<=COUNT_SCAN;end
            COUNT_SCAN:begin
                if(edge_bitmap[bitmap_cursor])selected_count<=selected_count+1'b1;
                if(bitmap_cursor==E-1)state<=EMIT_BEGIN;else bitmap_cursor<=bitmap_cursor+1'b1;
            end
            EMIT_BEGIN:begin bitmap_cursor<=0;emit_u<=0;emit_v<=1;state<=EMIT_SCAN;end
            EMIT_SCAN:begin if(edge_bitmap[bitmap_cursor])state<=EMIT_READ;else state<=EMIT_NEXT;end
            EMIT_READ:state<=EMIT_TAKE;
            EMIT_TAKE:begin out_u<=emit_u;out_v<=emit_v;out_weight<=matrix_q[W-1:0];state<=OUT_EDGE;end
            OUT_EDGE:if(m_ready)state<=EMIT_NEXT;
            EMIT_NEXT:begin
                if(bitmap_cursor==E-1)state<=OUT_SUM;
                else begin
                    bitmap_cursor<=bitmap_cursor+1'b1;
                    if(emit_v==N-1)begin emit_u<=emit_u+1'b1;emit_v<=emit_u+2;end
                    else emit_v<=emit_v+1'b1;
                    state<=EMIT_SCAN;
                end
            end
            OUT_SUM:if(m_ready)begin input_count<=0;in_u<=0;in_v<=1;state<=CAPTURE;end
            default:state<=CAPTURE;
        endcase
    end
endmodule
