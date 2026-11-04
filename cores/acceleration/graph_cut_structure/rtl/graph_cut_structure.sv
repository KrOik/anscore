// Original ANSCORE Apache-2.0 contribution; root LICENSE/NOTICE.
`timescale 1ns/1ps
module graph_cut_structure #(
    parameter integer NUM_NODES=16,TAG_W=8,
    localparam integer IW=(NUM_NODES>1?$clog2(NUM_NODES):1),
    localparam integer CW=$clog2(NUM_NODES+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [31:0] s_u,s_v,
    input wire s_present,s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg m_keep,m_last,m_error,
    output reg [TAG_W-1:0] m_tag,
    output reg [IW-1:0] m_node,m_component,
    output reg [CW-1:0] m_components,m_after_removal,m_degree,m_bridge_count,
    output reg m_cut_vertex,
    output reg [NUM_NODES-1:0] m_bridge_neighbors
);
    localparam integer N=NUM_NODES,AW=(N*N>1?$clog2(N*N):1);
    localparam [3:0] CLEAR=0,CAPTURE=1,MIRROR=2,START=3,INIT=4,
        ROOT=5,CHECK=6,READ=7,EXAMINE=8,RETURN=9,BRIDGE_REV=10,
        OUT_READ=11,OUT_CAPTURE=12,OUT_LOAD=13,OUTPUT=14;
    reg [3:0] state;
    reg adjacency[0:N*N-1],bridge[0:N*N-1];
    reg edge_q,bridge_q;
    reg [AW-1:0] clear_address;
    reg [IW-1:0] pending_u,pending_v;
    reg pending_present,pending_last;
    reg first,bad;
    reg [TAG_W-1:0] tag;
    reg [CW-1:0] discovery[0:N-1],low[0:N-1],next_neighbor[0:N-1];
    reg [CW-1:0] separated[0:N-1],degree[0:N-1];
    reg [IW-1:0] parent[0:N-1],component[0:N-1];
    reg parent_valid[0:N-1];
    reg [CW-1:0] cursor,clock_number,components,bridge_count;
    reg [IW-1:0] current,neighbor,return_parent,return_child;
    reg [IW-1:0] output_node;
    reg [CW-1:0] output_column;
    reg [N-1:0] bridge_mask;
    wire [CW-1:0] after_removal=parent_valid[output_node]
        ? components+separated[output_node]
        : components-1'b1+separated[output_node];
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUTPUT;
    // One-bit synchronous memories, with mutually exclusive read/write states.
    always @(posedge clk) if(!rst) begin
        if(state==CLEAR) begin adjacency[clear_address]<=0;bridge[clear_address]<=0;end
        if(state==CAPTURE && s_valid && s_keep && s_u<N && s_v<N && s_u!=s_v)
            adjacency[s_u*N+s_v]<=s_present;
        if(state==MIRROR) adjacency[pending_v*N+pending_u]<=pending_present;
        if(state==READ) edge_q<=adjacency[current*N+next_neighbor[current]];
        if(state==RETURN && parent_valid[current] && low[current]>discovery[parent[current]])
            bridge[parent[current]*N+current]<=1;
        if(state==BRIDGE_REV) bridge[return_child*N+return_parent]<=1;
        if(state==OUT_READ) bridge_q<=bridge[output_node*N+output_column];
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=CLEAR;clear_address<=0;first<=1;bad<=0;tag<=0;
            m_keep<=0;m_last<=0;m_error<=0;m_tag<=0;m_node<=0;m_component<=0;
            m_components<=0;m_after_removal<=0;m_degree<=0;m_bridge_count<=0;
            m_cut_vertex<=0;m_bridge_neighbors<=0;
        end else case(state)
            CLEAR: begin
                if(clear_address==N*N-1) begin state<=CAPTURE;first<=1;bad<=0;end
                else clear_address<=clear_address+1'b1;
            end
            CAPTURE: if(s_valid) begin
                if(first) begin tag<=s_tag;first<=0;end
                if(s_keep && (s_u>=N || s_v>=N))bad<=1;
                if(s_keep && s_u<N && s_v<N && s_u!=s_v) begin
                    pending_u<=s_u[IW-1:0];pending_v<=s_v[IW-1:0];
                    pending_present<=s_present;pending_last<=s_last;state<=MIRROR;
                end else if(s_last)state<=START;
            end
            MIRROR: state<=pending_last?START:CAPTURE;
            START: begin
                if(bad) begin
                    m_keep<=0;m_last<=1;m_error<=1;m_tag<=tag;m_node<=0;m_component<=0;
                    m_components<=0;m_after_removal<=0;m_degree<=0;m_bridge_count<=0;
                    m_cut_vertex<=0;m_bridge_neighbors<=0;state<=OUTPUT;
                end else begin cursor<=0;clock_number<=0;components<=0;bridge_count<=0;state<=INIT;end
            end
            INIT: begin
                discovery[cursor]<=0;low[cursor]<=0;next_neighbor[cursor]<=0;
                separated[cursor]<=0;degree[cursor]<=0;parent[cursor]<=0;
                parent_valid[cursor]<=0;component[cursor]<=0;
                if(cursor==N-1) begin cursor<=0;state<=ROOT;end
                else cursor<=cursor+1'b1;
            end
            ROOT: begin
                if(cursor==N) begin output_node<=0;output_column<=0;bridge_mask<=0;state<=OUT_READ;end
                else if(discovery[cursor]==0) begin
                    discovery[cursor]<=clock_number+1'b1;low[cursor]<=clock_number+1'b1;
                    clock_number<=clock_number+1'b1;component[cursor]<=components[IW-1:0];
                    components<=components+1'b1;current<=cursor[IW-1:0];
                    cursor<=cursor+1'b1;state<=CHECK;
                end else cursor<=cursor+1'b1;
            end
            CHECK: begin
                if(next_neighbor[current]==N)state<=RETURN;
                else begin neighbor<=next_neighbor[current][IW-1:0];state<=READ;end
            end
            READ: state<=EXAMINE;
            EXAMINE: begin
                next_neighbor[current]<=next_neighbor[current]+1'b1;
                if(edge_q) begin
                    degree[current]<=degree[current]+1'b1;
                    if(discovery[neighbor]==0) begin
                        parent[neighbor]<=current;parent_valid[neighbor]<=1;
                        discovery[neighbor]<=clock_number+1'b1;low[neighbor]<=clock_number+1'b1;
                        clock_number<=clock_number+1'b1;component[neighbor]<=component[current];
                        current<=neighbor;
                    end else if((!parent_valid[current] || neighbor!=parent[current]) && discovery[neighbor]<low[current])
                        low[current]<=discovery[neighbor];
                end
                state<=CHECK;
            end
            RETURN: begin
                if(!parent_valid[current])state<=ROOT;
                else begin
                    if(low[current]<low[parent[current]])low[parent[current]]<=low[current];
                    if(low[current]>=discovery[parent[current]])
                        separated[parent[current]]<=separated[parent[current]]+1'b1;
                    if(low[current]>discovery[parent[current]]) begin
                        bridge_count<=bridge_count+1'b1;
                        return_parent<=parent[current];return_child<=current;state<=BRIDGE_REV;
                    end else begin current<=parent[current];state<=CHECK;end
                end
            end
            BRIDGE_REV: begin current<=return_parent;state<=CHECK;end
            OUT_READ: state<=OUT_CAPTURE;
            OUT_CAPTURE: begin
                bridge_mask[output_column]<=bridge_q;
                if(output_column==N-1)state<=OUT_LOAD;
                else begin output_column<=output_column+1'b1;state<=OUT_READ;end
            end
            OUT_LOAD: begin
                m_keep<=1;m_last<=output_node==N-1;m_error<=0;m_tag<=tag;
                m_node<=output_node;m_component<=component[output_node];m_components<=components;
                m_after_removal<=after_removal;m_degree<=degree[output_node];m_bridge_count<=bridge_count;
                m_cut_vertex<=after_removal>components;m_bridge_neighbors<=bridge_mask;state<=OUTPUT;
            end
            OUTPUT: if(m_ready) begin
                if(m_last) begin clear_address<=0;state<=CLEAR;end
                else begin output_node<=output_node+1'b1;output_column<=0;bridge_mask<=0;state<=OUT_READ;end
            end
            default: begin clear_address<=0;state<=CLEAR;end
        endcase
    end
    generate if(NUM_NODES<1 || NUM_NODES>64 || TAG_W<1 || TAG_W>32) begin:invalid_parameters
        graph_cut_structure_invalid_parameters__see_README rejected();
    end endgenerate
endmodule
