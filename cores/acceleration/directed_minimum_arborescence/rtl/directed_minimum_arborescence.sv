`timescale 1ns/1ps
module directed_minimum_arborescence #(
    parameter integer NUM_NODES=8, MAX_EDGES=16, COST_W=8, TAG_W=8
) (
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire s_keep, s_last, s_error,
    input wire [31:0] s_from, s_to, s_root,
    input wire [COST_W-1:0] s_cost,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output wire m_summary, m_last, m_feasible,
    output wire [31:0] m_vertex, m_parent, m_edge_index,
    output wire [COST_W-1:0] m_cost,
    output wire [COST_W+((NUM_NODES<=2)?0:$clog2(NUM_NODES-1))-1:0] m_total_cost,
    output wire [3:0] m_errors,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer V=(NUM_NODES<=2)?1:$clog2(NUM_NODES);
    localparam integer VN=(NUM_NODES<2)?1:$clog2(NUM_NODES+1);
    localparam integer E=(MAX_EDGES<=2)?1:$clog2(MAX_EDGES);
    localparam integer EN=(MAX_EDGES<2)?1:$clog2(MAX_EDGES+1);
    localparam integer EA=(NUM_NODES*MAX_EDGES<=2)?1:$clog2(NUM_NODES*MAX_EDGES);
    localparam integer NA=(NUM_NODES*NUM_NODES<=2)?1:$clog2(NUM_NODES*NUM_NODES);
    localparam integer TW=COST_W+((NUM_NODES<=2)?0:$clog2(NUM_NODES-1));
    localparam integer EW=1+2*V+COST_W;
    localparam integer NP=COST_W, NE=COST_W+V, NC=COST_W+V+E;
    localparam integer NS=COST_W+2*V+E, NX=COST_W+3*V+E;
    localparam integer NF=COST_W+3*V+2*E, NW=NF+6;
    localparam [5:0] CAPTURE=0, INIT=1, MIN_EDGE_READ=2, MIN_EDGE_USE=3,
        MIN_NODE_READ=4, MIN_NODE_USE=5, MIN_NEXT=6, VERIFY_READ=7,
        VERIFY_USE=8, WALK_READ=9, WALK_USE=10, CYCLE_READ=11, CYCLE_USE=12,
        WALK_NEXT=13, COMPONENT_READ=14, COMPONENT_USE=15, ROOT_READ=16,
        ROOT_USE=17, CONTRACT_EDGE_READ=18, CONTRACT_EDGE_USE=19,
        CONTRACT_FROM_READ=20, CONTRACT_FROM_USE=21, CONTRACT_TO_READ=22,
        CONTRACT_TO_USE=23, CONTRACT_NEXT=24, LAYER_NEXT=25, SELECT_READ=26,
        SELECT_USE=27, EXPAND_INIT_READ=28, EXPAND_INIT_USE=29,
        EXPAND_NODE_READ=30, EXPAND_NODE_USE=31, EXPAND_EDGE_READ=32,
        EXPAND_EDGE_USE=33, EXPAND_DEST_READ=34, EXPAND_DEST_USE=35,
        EXPAND_NEXT=36, SUM_NODE_READ=37, SUM_NODE_USE=38, SUM_EDGE_READ=39,
        SUM_EDGE_USE=40, OUTPUT_NODE_READ=41, OUTPUT_NODE_USE=42,
        OUTPUT_EDGE_READ=43, OUTPUT_EDGE_USE=44, OUTPUT_HOLD=45, SUMMARY=46;

    generate if(NUM_NODES<1 || NUM_NODES>12 || MAX_EDGES<1 || MAX_EDGES>32 ||
                COST_W<1 || COST_W>12 || TAG_W<1 || TAG_W>32) begin: invalid_parameters
        DIRECTED_MINIMUM_ARBORESCENCE_INVALID_PARAMETERS invalid();
    end endgenerate

    // Fixed original-edge slots survive every layer. The banks retain history
    // needed for expansion, rather than a register graph or combinational search.
    reg [EW-1:0] edge_mem [0:NUM_NODES*MAX_EDGES-1];
    reg [NW-1:0] node_mem [0:NUM_NODES*NUM_NODES-1];
    reg [EW-1:0] edge_q;
    reg [NW-1:0] node_q;
    reg e_re,e_we,n_re,n_we;
    reg [EA-1:0] e_addr;
    reg [NA-1:0] n_addr;
    reg [EW-1:0] e_wdata;
    reg [NW-1:0] n_wdata;
    reg [5:0] state;
    reg capture_active, feasible, has_cycle;
    reg [3:0] errors, error_next;
    reg [TAG_W-1:0] tag;
    reg [EN-1:0] edge_count;
    reg [E-1:0] edge_index, selected_index;
    reg [VN-1:0] node_count, component_count;
    reg [V-1:0] root, next_root, layer, node_index;
    reg [V-1:0] walk_start, cursor, cycle_anchor, from_component;
    reg [TW-1:0] total;
    wire [COST_W-1:0] eq_cost=edge_q[0+:COST_W];
    wire [V-1:0] eq_to=edge_q[COST_W+:V];
    wire [V-1:0] eq_from=edge_q[COST_W+V+:V];
    wire eq_valid=edge_q[EW-1];
    wire [COST_W-1:0] nq_cost=node_q[0+:COST_W];
    wire [V-1:0] nq_parent=node_q[NP+:V];
    wire [E-1:0] nq_edge=node_q[NE+:E];
    wire [V-1:0] nq_component=node_q[NC+:V];
    wire [V-1:0] nq_seen=node_q[NS+:V];
    wire [E-1:0] nq_selected=node_q[NX+:E];
    wire nq_active=node_q[NF], nq_root=node_q[NF+1];
    wire nq_min_valid=node_q[NF+2], nq_component_valid=node_q[NF+3];
    wire nq_seen_valid=node_q[NF+4], nq_selected_valid=node_q[NF+5];

    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && (state==OUTPUT_HOLD || state==SUMMARY);
    assign m_summary=!rst && state==SUMMARY;
    assign m_last=m_summary;
    assign m_feasible=m_valid && feasible;
    assign m_vertex=(m_valid && !m_summary)?eq_to:32'b0;
    assign m_parent=(m_valid && !m_summary)?eq_from:32'b0;
    assign m_edge_index=(m_valid && !m_summary)?selected_index:32'b0;
    assign m_cost=(m_valid && !m_summary)?eq_cost:{COST_W{1'b0}};
    assign m_total_cost=m_valid?total:{TW{1'b0}};
    assign m_errors=m_valid?errors:4'b0;
    assign m_tag=m_valid?tag:{TAG_W{1'b0}};

    always @* begin
        error_next=errors;
        if(!capture_active && s_root>=NUM_NODES) error_next[0]=1'b1;
        if(s_keep && (s_from>=NUM_NODES || s_to>=NUM_NODES)) error_next[1]=1'b1;
        if(s_keep && edge_count>=MAX_EDGES) error_next[2]=1'b1;
        if(s_error) error_next[3]=1'b1;
    end

    // Each memory performs at most ONE operation at an edge. No collision
    // mode, asynchronous read, payload reset or RAM replication is required.
    always @(posedge clk) if(!rst) begin
        if(e_we) edge_mem[e_addr]<=e_wdata;
        if(e_re) edge_q<=edge_mem[e_addr];
        if(n_we) node_mem[n_addr]<=n_wdata;
        if(n_re) node_q<=node_mem[n_addr];
    end

    always @* begin
        e_re=0;e_we=0;n_re=0;n_we=0;e_addr=0;n_addr=0;
        e_wdata=0;n_wdata=node_q;
        case(state)
        CAPTURE: if(s_valid && s_ready && s_keep && edge_count<MAX_EDGES &&
                    s_from<NUM_NODES && s_to<NUM_NODES) begin
            e_we=1;e_addr=edge_count;
            e_wdata={1'b1,s_from[V-1:0],s_to[V-1:0],s_cost};
        end
        INIT: begin
            n_we=1;n_addr=layer*NUM_NODES+node_index;n_wdata=0;
            n_wdata[NF]=(node_index<node_count);
            n_wdata[NF+1]=(node_index==root);
            n_wdata[NF+2]=(node_index==root);
        end
        MIN_EDGE_READ, CONTRACT_EDGE_READ: if(edge_count!=0) begin
            e_re=1;e_addr=layer*MAX_EDGES+edge_index;
        end
        MIN_NODE_READ: begin n_re=1;n_addr=layer*NUM_NODES+eq_to;end
        MIN_NODE_USE: if(!nq_min_valid || eq_cost<nq_cost) begin
            n_we=1;n_addr=layer*NUM_NODES+eq_to;
            n_wdata[0+:COST_W]=eq_cost;n_wdata[NP+:V]=eq_from;
            n_wdata[NE+:E]=edge_index;n_wdata[NF+2]=1;
        end
        VERIFY_READ, COMPONENT_READ, SELECT_READ, EXPAND_NODE_READ: begin
            n_re=1;n_addr=layer*NUM_NODES+node_index;
        end
        WALK_READ, CYCLE_READ: begin n_re=1;n_addr=layer*NUM_NODES+cursor;end
        WALK_USE: if(!nq_root && !nq_component_valid && !(nq_seen_valid && nq_seen==walk_start)) begin
            n_we=1;n_addr=layer*NUM_NODES+cursor;
            n_wdata[NS+:V]=walk_start;n_wdata[NF+4]=1;
        end
        CYCLE_USE: begin
            n_we=1;n_addr=layer*NUM_NODES+cursor;
            n_wdata[NC+:V]=component_count[V-1:0];n_wdata[NF+3]=1;
        end
        COMPONENT_USE: if(!nq_component_valid) begin
            n_we=1;n_addr=layer*NUM_NODES+node_index;
            n_wdata[NC+:V]=component_count[V-1:0];n_wdata[NF+3]=1;
        end
        ROOT_READ: begin n_re=1;n_addr=layer*NUM_NODES+root;end
        CONTRACT_EDGE_USE: if(!eq_valid) begin
            e_we=1;e_addr=(layer+1)*MAX_EDGES+edge_index;e_wdata=0;
        end
        CONTRACT_FROM_READ: begin n_re=1;n_addr=layer*NUM_NODES+eq_from;end
        CONTRACT_TO_READ: begin n_re=1;n_addr=layer*NUM_NODES+eq_to;end
        CONTRACT_TO_USE: begin
            e_we=1;e_addr=(layer+1)*MAX_EDGES+edge_index;
            // Crossing edge costs cannot increase or become negative: every
            // incoming nonloop cost is >= the selected minimum at its target.
            if(from_component!=nq_component)
                e_wdata={1'b1,from_component,nq_component,eq_cost-nq_cost};
        end
        SELECT_USE: begin
            n_we=1;n_addr=layer*NUM_NODES+node_index;
            n_wdata[NX+:E]=nq_edge;n_wdata[NF+5]=nq_active && !nq_root;
        end
        EXPAND_INIT_READ: begin n_re=1;n_addr=(layer-1)*NUM_NODES+node_index;end
        EXPAND_INIT_USE: begin
            n_we=1;n_addr=(layer-1)*NUM_NODES+node_index;
            n_wdata[NX+:E]=nq_edge;n_wdata[NF+5]=nq_active && !nq_root;
        end
        EXPAND_EDGE_READ: begin e_re=1;e_addr=(layer-1)*MAX_EDGES+selected_index;end
        EXPAND_DEST_READ: begin n_re=1;n_addr=(layer-1)*NUM_NODES+cursor;end
        EXPAND_DEST_USE: begin
            n_we=1;n_addr=(layer-1)*NUM_NODES+cursor;
            n_wdata[NX+:E]=selected_index;n_wdata[NF+5]=1;
        end
        SUM_NODE_READ, OUTPUT_NODE_READ: begin n_re=1;n_addr=node_index;end
        SUM_EDGE_READ, OUTPUT_EDGE_READ: begin e_re=1;e_addr=selected_index;end
        default: begin end
        endcase
    end

    always @(posedge clk) begin
        if(rst) begin
            state<=CAPTURE;capture_active<=0;feasible<=0;has_cycle<=0;
            errors<=0;tag<=0;edge_count<=0;edge_index<=0;selected_index<=0;
            node_count<=0;component_count<=0;root<=0;next_root<=0;layer<=0;
            node_index<=0;walk_start<=0;cursor<=0;cycle_anchor<=0;from_component<=0;total<=0;
        end else case(state)
        CAPTURE: if(s_valid && s_ready) begin
            capture_active<=1;errors<=error_next;
            if(!capture_active) begin root<=s_root[V-1:0];tag<=s_tag;end
            if(s_keep && edge_count<MAX_EDGES) edge_count<=edge_count+1'b1;
            if(s_last) begin
                total<=0;feasible<=(error_next==0);
                if(error_next!=0) state<=SUMMARY;
                else begin state<=INIT;node_count<=NUM_NODES;layer<=0;node_index<=0;end
            end
        end
        INIT: if(node_index==NUM_NODES-1) begin
            edge_index<=0;component_count<=0;has_cycle<=0;state<=MIN_EDGE_READ;
        end else node_index<=node_index+1'b1;
        MIN_EDGE_READ: if(edge_count==0) begin node_index<=0;state<=VERIFY_READ;end
                       else state<=MIN_EDGE_USE;
        MIN_EDGE_USE: if(eq_valid && eq_from!=eq_to && eq_to!=root) state<=MIN_NODE_READ;
                      else state<=MIN_NEXT;
        MIN_NODE_READ: state<=MIN_NODE_USE;
        MIN_NODE_USE: state<=MIN_NEXT;
        MIN_NEXT: if(edge_index==edge_count-1'b1) begin node_index<=0;state<=VERIFY_READ;end
                  else begin edge_index<=edge_index+1'b1;state<=MIN_EDGE_READ;end
        VERIFY_READ: state<=VERIFY_USE;
        VERIFY_USE: if(!nq_min_valid) begin feasible<=0;total<=0;state<=SUMMARY;end
                    else if(node_index==node_count-1'b1) begin walk_start<=0;cursor<=0;state<=WALK_READ;end
                    else begin node_index<=node_index+1'b1;state<=VERIFY_READ;end
        WALK_READ: state<=WALK_USE;
        WALK_USE: if(nq_root || nq_component_valid) state<=WALK_NEXT;
                  else if(nq_seen_valid && nq_seen==walk_start) begin cycle_anchor<=cursor;state<=CYCLE_READ;end
                  else begin cursor<=nq_parent;state<=WALK_READ;end
        CYCLE_READ: state<=CYCLE_USE;
        CYCLE_USE: if(nq_parent==cycle_anchor) begin
            component_count<=component_count+1'b1;has_cycle<=1;state<=WALK_NEXT;
        end else begin cursor<=nq_parent;state<=CYCLE_READ;end
        WALK_NEXT: if(walk_start==node_count-1'b1) begin
            node_index<=0;state<=has_cycle?COMPONENT_READ:SELECT_READ;
        end else begin walk_start<=walk_start+1'b1;cursor<=walk_start+1'b1;state<=WALK_READ;end
        COMPONENT_READ: state<=COMPONENT_USE;
        COMPONENT_USE: begin
            if(!nq_component_valid) component_count<=component_count+1'b1;
            if(node_index==node_count-1'b1) state<=ROOT_READ;
            else begin node_index<=node_index+1'b1;state<=COMPONENT_READ;end
        end
        ROOT_READ: state<=ROOT_USE;
        ROOT_USE: begin next_root<=nq_component;edge_index<=0;state<=CONTRACT_EDGE_READ;end
        CONTRACT_EDGE_READ: state<=CONTRACT_EDGE_USE;
        CONTRACT_EDGE_USE: state<=eq_valid?CONTRACT_FROM_READ:CONTRACT_NEXT;
        CONTRACT_FROM_READ: state<=CONTRACT_FROM_USE;
        CONTRACT_FROM_USE: begin from_component<=nq_component;state<=CONTRACT_TO_READ;end
        CONTRACT_TO_READ: state<=CONTRACT_TO_USE;
        CONTRACT_TO_USE: state<=CONTRACT_NEXT;
        CONTRACT_NEXT: if(edge_index==edge_count-1'b1) state<=LAYER_NEXT;
                       else begin edge_index<=edge_index+1'b1;state<=CONTRACT_EDGE_READ;end
        LAYER_NEXT: begin
            layer<=layer+1'b1;node_count<=component_count;root<=next_root;node_index<=0;state<=INIT;
        end
        SELECT_READ: state<=SELECT_USE;
        SELECT_USE: if(node_index==NUM_NODES-1) begin
            node_index<=0;state<=(layer==0)?SUM_NODE_READ:EXPAND_INIT_READ;
        end else begin node_index<=node_index+1'b1;state<=SELECT_READ;end
        EXPAND_INIT_READ: state<=EXPAND_INIT_USE;
        EXPAND_INIT_USE: if(node_index==NUM_NODES-1) begin node_index<=0;state<=EXPAND_NODE_READ;end
                         else begin node_index<=node_index+1'b1;state<=EXPAND_INIT_READ;end
        EXPAND_NODE_READ: state<=EXPAND_NODE_USE;
        EXPAND_NODE_USE: if(nq_selected_valid) begin selected_index<=nq_selected;state<=EXPAND_EDGE_READ;end
                         else if(node_index==NUM_NODES-1) state<=EXPAND_NEXT;
                         else begin node_index<=node_index+1'b1;state<=EXPAND_NODE_READ;end
        EXPAND_EDGE_READ: state<=EXPAND_EDGE_USE;
        EXPAND_EDGE_USE: begin cursor<=eq_to;state<=EXPAND_DEST_READ;end
        EXPAND_DEST_READ: state<=EXPAND_DEST_USE;
        EXPAND_DEST_USE: if(node_index==NUM_NODES-1) state<=EXPAND_NEXT;
                         else begin node_index<=node_index+1'b1;state<=EXPAND_NODE_READ;end
        EXPAND_NEXT: begin
            layer<=layer-1'b1;node_index<=0;state<=(layer==1)?SUM_NODE_READ:EXPAND_INIT_READ;
        end
        SUM_NODE_READ: state<=SUM_NODE_USE;
        SUM_NODE_USE: if(nq_selected_valid) begin selected_index<=nq_selected;state<=SUM_EDGE_READ;end
                      else if(node_index==NUM_NODES-1) begin node_index<=0;state<=OUTPUT_NODE_READ;end
                      else begin node_index<=node_index+1'b1;state<=SUM_NODE_READ;end
        SUM_EDGE_READ: state<=SUM_EDGE_USE;
        SUM_EDGE_USE: begin
            total<=total+eq_cost;
            if(node_index==NUM_NODES-1) begin node_index<=0;state<=OUTPUT_NODE_READ;end
            else begin node_index<=node_index+1'b1;state<=SUM_NODE_READ;end
        end
        OUTPUT_NODE_READ: state<=OUTPUT_NODE_USE;
        OUTPUT_NODE_USE: if(nq_selected_valid) begin selected_index<=nq_selected;state<=OUTPUT_EDGE_READ;end
                         else if(node_index==NUM_NODES-1) state<=SUMMARY;
                         else begin node_index<=node_index+1'b1;state<=OUTPUT_NODE_READ;end
        OUTPUT_EDGE_READ: state<=OUTPUT_EDGE_USE;
        OUTPUT_EDGE_USE: state<=OUTPUT_HOLD;
        OUTPUT_HOLD: if(m_ready) begin
            if(node_index==NUM_NODES-1) state<=SUMMARY;
            else begin node_index<=node_index+1'b1;state<=OUTPUT_NODE_READ;end
        end
        SUMMARY: if(m_ready) begin
            state<=CAPTURE;capture_active<=0;edge_count<=0;errors<=0;feasible<=0;total<=0;
        end
        default: state<=CAPTURE;
        endcase
    end
endmodule
