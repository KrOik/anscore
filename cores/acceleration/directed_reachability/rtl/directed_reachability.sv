// Original ANSCORE Apache-2.0 contribution; root LICENSE and NOTICE.
`timescale 1ns/1ps
module directed_reachability #(
    parameter integer NUM_NODES=16,TAG_W=8,
    localparam integer IW=(NUM_NODES>1?$clog2(NUM_NODES):1),
    localparam integer CW=$clog2(NUM_NODES+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,
    input wire s_present,s_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg m_keep,m_last,m_error,output reg [TAG_W-1:0] m_tag,
    output reg [IW-1:0] m_node,m_scc_root,
    output reg [CW-1:0] m_scc_size,m_components,m_forward_count,m_backward_count,
    output reg [NUM_NODES-1:0] m_reachable,m_scc_members,
    output reg m_cyclic,m_acyclic
);
    localparam integer N=NUM_NODES,SW=N+IW+3*CW;
    localparam [N-1:0] ONE={{(N-1){1'b0}},1'b1};
    localparam [4:0] INIT=0,CAPTURE=1,IN_READ=2,IN_WRITE=3,START=4,
        PIVOT_READ=5,PIVOT_SET=6,ROW_READ=7,ROW_UPDATE=8,
        SCC_READ=9,SCC_SET=10,REV_READ=11,REV_CHECK=12,SCC_COMMIT=13,
        OUT_READ=14,OUT_LOAD=15,OUTPUT=16;
    reg [4:0] state;
    reg [N-1:0] closure[0:N-1];
    reg [SW-1:0] summaries[0:N-1];
    reg [N-1:0] row_q,pivot_row,forward_row,scc_mask,self_loops;
    reg [SW-1:0] summary_q;
    reg [IW-1:0] initialize_row,pending_from,pending_to,pivot,target_row,scc_row,reverse_row,representative,output_node;
    reg pending_present,pending_last,first,bad,representative_valid,cycle_found;
    reg [CW-1:0] scc_size,forward_count,backward_count,component_count;
    reg [TAG_W-1:0] tag;
    reg [N-1:0] input_update;
    always @* begin input_update=row_q;input_update[pending_to]=pending_present;end
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUTPUT;
    // Each memory has synchronous reads and writes in disjoint phases.
    always @(posedge clk) if(!rst) begin
        if(state==INIT)closure[initialize_row]<=ONE<<initialize_row;
        if(state==IN_READ)row_q<=closure[pending_from];
        if(state==IN_WRITE)closure[pending_from]<=input_update;
        if(state==PIVOT_READ)row_q<=closure[pivot];
        if(state==ROW_READ)row_q<=closure[target_row];
        if(state==ROW_UPDATE && row_q[pivot])closure[target_row]<=row_q|pivot_row;
        if(state==SCC_READ)row_q<=closure[scc_row];
        if(state==REV_READ)row_q<=closure[reverse_row];
        if(state==SCC_COMMIT)summaries[scc_row]<={scc_mask,representative,scc_size,forward_count,backward_count};
        if(state==OUT_READ)begin row_q<=closure[output_node];summary_q<=summaries[output_node];end
    end
    always @(posedge clk) begin
        if(rst)begin
            state<=INIT;initialize_row<=0;self_loops<=0;first<=1;bad<=0;tag<=0;
            m_keep<=0;m_last<=0;m_error<=0;m_tag<=0;m_node<=0;m_scc_root<=0;
            m_scc_size<=0;m_components<=0;m_forward_count<=0;m_backward_count<=0;
            m_reachable<=0;m_scc_members<=0;m_cyclic<=0;m_acyclic<=0;
        end else case(state)
            INIT:begin
                self_loops[initialize_row]<=0;
                if(initialize_row==N-1)begin first<=1;bad<=0;state<=CAPTURE;end
                else initialize_row<=initialize_row+1'b1;
            end
            CAPTURE:if(s_valid)begin
                if(first)begin tag<=s_tag;first<=0;end
                if(s_keep && (s_from>=N || s_to>=N))bad<=1;
                if(s_keep && s_from<N && s_to<N)begin
                    if(s_from==s_to)begin
                        self_loops[s_from]<=s_present;
                        if(s_last)state<=START;
                    end else begin
                        pending_from<=s_from[IW-1:0];pending_to<=s_to[IW-1:0];
                        pending_present<=s_present;pending_last<=s_last;state<=IN_READ;
                    end
                end else if(s_last)state<=START;
            end
            IN_READ:state<=IN_WRITE;
            IN_WRITE:state<=pending_last?START:CAPTURE;
            START:begin
                if(bad)begin
                    m_keep<=0;m_last<=1;m_error<=1;m_tag<=tag;m_node<=0;m_scc_root<=0;
                    m_scc_size<=0;m_components<=0;m_forward_count<=0;m_backward_count<=0;
                    m_reachable<=0;m_scc_members<=0;m_cyclic<=0;m_acyclic<=0;state<=OUTPUT;
                end else begin pivot<=0;component_count<=0;cycle_found<=0;state<=PIVOT_READ;end
            end
            PIVOT_READ:state<=PIVOT_SET;
            PIVOT_SET:begin pivot_row<=row_q;target_row<=0;state<=ROW_READ;end
            ROW_READ:state<=ROW_UPDATE;
            ROW_UPDATE:begin
                if(target_row==N-1)begin
                    if(pivot==N-1)begin scc_row<=0;state<=SCC_READ;end
                    else begin pivot<=pivot+1'b1;state<=PIVOT_READ;end
                end else begin target_row<=target_row+1'b1;state<=ROW_READ;end
            end
            SCC_READ:state<=SCC_SET;
            SCC_SET:begin
                forward_row<=row_q;reverse_row<=0;scc_mask<=0;representative<=0;
                representative_valid<=0;scc_size<=0;forward_count<=0;backward_count<=0;state<=REV_READ;
            end
            REV_READ:state<=REV_CHECK;
            REV_CHECK:begin
                if(forward_row[reverse_row])forward_count<=forward_count+1'b1;
                if(row_q[scc_row])backward_count<=backward_count+1'b1;
                if(forward_row[reverse_row] && row_q[scc_row])begin
                    scc_mask[reverse_row]<=1;scc_size<=scc_size+1'b1;
                    if(!representative_valid)begin representative<=reverse_row;representative_valid<=1;end
                end
                if(reverse_row==N-1)state<=SCC_COMMIT;
                else begin reverse_row<=reverse_row+1'b1;state<=REV_READ;end
            end
            SCC_COMMIT:begin
                if(representative==scc_row)component_count<=component_count+1'b1;
                if(scc_size>1 || self_loops[scc_row])cycle_found<=1;
                if(scc_row==N-1)begin output_node<=0;state<=OUT_READ;end
                else begin scc_row<=scc_row+1'b1;state<=SCC_READ;end
            end
            OUT_READ:state<=OUT_LOAD;
            OUT_LOAD:begin
                m_keep<=1;m_last<=output_node==N-1;m_error<=0;m_tag<=tag;m_node<=output_node;
                m_reachable<=row_q;
                {m_scc_members,m_scc_root,m_scc_size,m_forward_count,m_backward_count}<=summary_q;
                m_components<=component_count;m_cyclic<=summary_q[2*CW +:CW]>1 || self_loops[output_node];
                m_acyclic<=!cycle_found;state<=OUTPUT;
            end
            OUTPUT:if(m_ready)begin
                if(m_last)begin initialize_row<=0;state<=INIT;end
                else begin output_node<=output_node+1'b1;state<=OUT_READ;end
            end
            default:begin initialize_row<=0;state<=INIT;end
        endcase
    end
    generate if(NUM_NODES<1 || NUM_NODES>64 || TAG_W<1 || TAG_W>32)begin:invalid_parameters
        directed_reachability_invalid_parameters__see_README rejected();
    end endgenerate
endmodule
