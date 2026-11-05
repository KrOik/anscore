// Original ANSCORE Apache-2.0 contribution; package LICENSE and NOTICE.
`timescale 1ns/1ps
module dag_transitive_reduction #(
    parameter integer NUM_NODES=16, TAG_W=8,
    localparam integer IW=(NUM_NODES>1?$clog2(NUM_NODES):1),
    localparam integer CW=$clog2(NUM_NODES+1),
    localparam integer EW=$clog2(NUM_NODES*NUM_NODES+1)
)(
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire [31:0] s_from, s_to,
    input wire s_present, s_keep, s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg m_keep, m_last,
    output reg [1:0] m_errors,
    output reg [TAG_W-1:0] m_tag,
    output reg [IW-1:0] m_node,
    output reg [NUM_NODES-1:0] m_successors,
    output reg [CW-1:0] m_out_degree,
    output reg [EW-1:0] m_edge_count, m_removed_count
);
    localparam integer N=NUM_NODES, RW=N+CW;
    localparam [N-1:0] ONE={{(N-1){1'b0}},1'b1};
    localparam [3:0] INIT=0, CAPTURE=1, IN_READ=2, IN_WRITE=3,
        COLLECT=4, ADJ_READ=5, ADJ_LOAD=6, NEXT_SUCC=7,
        REACH_READ=8, REACH_USE=9, FILTER=10, COUNT=11,
        COMMIT=12, OUT_READ=13, OUT_LOAD=14, OUTPUT=15;
    reg [3:0] state;
    reg [N-1:0] adjacency[0:N-1];
    reg [N-1:0] reachability[0:N-1];
    reg [RW-1:0] reduced_rows[0:N-1];
    reg [N-1:0] adjacency_q, reach_q, direct_row, redundant, reduced_mask;
    reg [RW-1:0] reduced_q;
    reg [IW-1:0] init_row, pending_from, pending_to, compute_row,
        successor, count_bit, output_node;
    reg pending_present, pending_last, first;
    reg [TAG_W-1:0] tag;
    reg [1:0] frame_error;
    reg [CW-1:0] degree;
    reg [EW-1:0] original_edges, reduced_edges;
    reg [N-1:0] update_row;
    wire backend_ready, backend_valid, backend_keep, backend_last;
    wire backend_error, backend_acyclic;
    wire [IW-1:0] backend_node;
    wire [N-1:0] backend_reachable;
    wire backend_accept=backend_valid && state==COLLECT && !rst;
    assign s_ready=!rst && state==CAPTURE && backend_ready;
    assign m_valid=!rst && state==OUTPUT;
    always @* begin
        update_row=adjacency_q;
        update_row[pending_to]=pending_present;
    end
    // The mature backend is reused unchanged. Both consumers accept each
    // external token on exactly the same edge; wrapper RMW may add stalls.
    directed_reachability #(.NUM_NODES(N),.TAG_W(TAG_W)) closure_backend(
        .clk(clk),.rst(rst),.s_valid(s_valid && state==CAPTURE && !rst),
        .s_ready(backend_ready),.s_from(s_from),.s_to(s_to),
        .s_present(s_present),.s_keep(s_keep),.s_last(s_last),.s_tag(s_tag),
        .m_valid(backend_valid),.m_ready(state==COLLECT && !rst),
        .m_keep(backend_keep),.m_last(backend_last),.m_error(backend_error),
        .m_tag(),.m_node(backend_node),.m_scc_root(),.m_scc_size(),
        .m_components(),.m_forward_count(),.m_backward_count(),
        .m_reachable(backend_reachable),.m_scc_members(),.m_cyclic(),
        .m_acyclic(backend_acyclic)
    );
    // Each local bank has one synchronous read OR write per edge.
    // Payload and read-q registers are deliberately unreset.
    always @(posedge clk) if(!rst) begin
        if(state==INIT)adjacency[init_row]<=0;
        if(state==IN_READ)adjacency_q<=adjacency[pending_from];
        if(state==IN_WRITE)adjacency[pending_from]<=update_row;
        if(state==ADJ_READ)adjacency_q<=adjacency[compute_row];
        if(backend_accept && backend_keep && !backend_error)
            reachability[backend_node]<=backend_reachable;
        if(state==REACH_READ)reach_q<=reachability[successor];
        if(state==COMMIT)reduced_rows[compute_row]<={degree,reduced_mask};
        if(state==OUT_READ)reduced_q<=reduced_rows[output_node];
    end
    always @(posedge clk) begin
        if(rst)begin
            state<=INIT;init_row<=0;first<=1;tag<=0;frame_error<=0;
            original_edges<=0;reduced_edges<=0;
            m_keep<=0;m_last<=0;m_errors<=0;m_tag<=0;m_node<=0;
            m_successors<=0;m_out_degree<=0;m_edge_count<=0;m_removed_count<=0;
        end else case(state)
            INIT:begin
                if(init_row==N-1)begin
                    first<=1;frame_error<=0;original_edges<=0;reduced_edges<=0;
                    state<=CAPTURE;
                end else init_row<=init_row+1'b1;
            end
            CAPTURE:if(s_valid && backend_ready)begin
                if(first)begin tag<=s_tag;first<=0;end
                // Complete unsigned32 validation precedes every address cast.
                if(s_keep && s_from<N && s_to<N)begin
                    pending_from<=s_from[IW-1:0];pending_to<=s_to[IW-1:0];
                    pending_present<=s_present;pending_last<=s_last;state<=IN_READ;
                end else if(s_last)state<=COLLECT;
            end
            IN_READ:state<=IN_WRITE;
            IN_WRITE:state<=pending_last?COLLECT:CAPTURE;
            COLLECT:if(backend_valid && backend_last)begin
                output_node<=0;
                if(backend_error)begin frame_error<=2'b01;state<=OUT_LOAD;end
                else if(!backend_acyclic)begin frame_error<=2'b10;state<=OUT_LOAD;end
                else begin compute_row<=0;state<=ADJ_READ;end
            end
            ADJ_READ:state<=ADJ_LOAD;
            ADJ_LOAD:begin
                direct_row<=adjacency_q;redundant<=0;successor<=0;state<=NEXT_SUCC;
            end
            NEXT_SUCC:begin
                if(direct_row[successor])begin
                    original_edges<=original_edges+1'b1;state<=REACH_READ;
                end else if(successor==N-1)state<=FILTER;
                else successor<=successor+1'b1;
            end
            REACH_READ:state<=REACH_USE;
            REACH_USE:begin
                // A direct successor cannot remove its own edge via the
                // backend's reflexive diagonal. Other descendants are redundant.
                redundant<=redundant | (reach_q & ~(ONE<<successor));
                if(successor==N-1)state<=FILTER;
                else begin successor<=successor+1'b1;state<=NEXT_SUCC;end
            end
            FILTER:begin
                reduced_mask<=direct_row & ~redundant;
                degree<=0;count_bit<=0;state<=COUNT;
            end
            COUNT:begin
                if(reduced_mask[count_bit])begin
                    degree<=degree+1'b1;reduced_edges<=reduced_edges+1'b1;
                end
                if(count_bit==N-1)state<=COMMIT;
                else count_bit<=count_bit+1'b1;
            end
            COMMIT:begin
                if(compute_row==N-1)state<=OUT_READ;
                else begin compute_row<=compute_row+1'b1;state<=ADJ_READ;end
            end
            OUT_READ:state<=OUT_LOAD;
            OUT_LOAD:begin
                m_tag<=tag;m_errors<=frame_error;
                if(frame_error!=0)begin
                    m_keep<=0;m_last<=1;m_node<=0;m_successors<=0;
                    m_out_degree<=0;m_edge_count<=0;m_removed_count<=0;
                end else begin
                    m_keep<=1;m_last<=output_node==N-1;m_node<=output_node;
                    {m_out_degree,m_successors}<=reduced_q;
                    m_edge_count<=reduced_edges;m_removed_count<=original_edges-reduced_edges;
                end
                state<=OUTPUT;
            end
            OUTPUT:if(m_ready)begin
                if(m_last)begin init_row<=0;state<=INIT;end
                else begin output_node<=output_node+1'b1;state<=OUT_READ;end
            end
            default:begin init_row<=0;state<=INIT;end
        endcase
    end
    generate if(NUM_NODES<1 || NUM_NODES>64 || TAG_W<1 || TAG_W>32)begin:invalid_parameters
        dag_transitive_reduction_invalid_parameters__see_README rejected();
    end endgenerate
endmodule
