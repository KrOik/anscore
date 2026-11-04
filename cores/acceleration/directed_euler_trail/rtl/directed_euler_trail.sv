// SPDX-License-Identifier: Apache-2.0
module directed_euler_trail #(
    parameter integer NUM_NODES=8,
    parameter integer MAX_EDGES=32,
    parameter integer TAG_W=8
)(
    input wire clk,input wire rst,
    input wire c_valid,output wire c_ready,
    input wire [31:0] c_start,input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,
    input wire [31:0] s_from,input wire [31:0] s_to,
    input wire s_keep,input wire s_last,
    output wire m_valid,input wire m_ready,
    output wire [31:0] m_node,output wire [31:0] m_in_edge,
    output wire [31:0] m_step,output wire [31:0] m_edges,
    output wire m_has_edge,output wire m_keep,output wire m_last,
    output wire [3:0] m_error,output wire [TAG_W-1:0] m_tag
);
    localparam integer V=(NUM_NODES>1)?$clog2(NUM_NODES):1;
    localparam integer E=(MAX_EDGES>1)?$clog2(MAX_EDGES):1;
    localparam integer C=$clog2(MAX_EDGES+1);
    localparam integer R=$clog2(MAX_EDGES+2);
    generate if(NUM_NODES<1 || NUM_NODES>16 || MAX_EDGES<1 || MAX_EDGES>64 || TAG_W<1 || TAG_W>32)begin:bad
        directed_euler_trail_invalid_parameters__see_README invalid();
    end endgenerate
    localparam [4:0] IDLE=0,LOAD=1,INIT=2,SCAN_READ=3,SCAN_USE=4,PUSH=5,
        APPEND=6,POP_READ=7,POP_USE=8,CHECK=9,VERIFY_READ=10,VERIFY_USE=11,
        EDGE_READ=12,EDGE_USE=13,OUT_READ=14,OUT_USE=15,HOLD=16;
    reg [4:0] state;
    reg [2*V-1:0] edges[0:MAX_EDGES-1];
    reg [V+E-1:0] stack[0:MAX_EDGES-1];
    reg [V+E-1:0] route[0:MAX_EDGES];
    reg [2*V-1:0] edge_q;
    reg [V+E-1:0] stack_q,route_q;
    reg [MAX_EDGES-1:0] used;
    reg [C-1:0] edge_count,used_count,sp,verify_index,out_index;
    reg [R-1:0] route_count;
    reg [E-1:0] scan,cur_in,verify_edge,out_edge;
    reg [V-1:0] start_node,cur,previous,next_node,out_node;
    reg [TAG_W-1:0] tag;
    reg [3:0] input_error,out_error;
    wire [3:0] row_error=input_error | ((s_keep && (s_from>=NUM_NODES || s_to>=NUM_NODES))?4'd2:4'd0)
                         | ((s_keep && edge_count==MAX_EDGES)?4'd4:4'd0);
    assign c_ready=!rst && state==IDLE;
    assign s_ready=!rst && state==LOAD;
    assign m_valid=!rst && state==HOLD;
    assign m_keep=m_valid && out_error==0;
    assign m_last=m_valid && (out_error!=0 || out_index==0);
    assign m_node=out_node;
    assign m_in_edge=out_edge;
    assign m_step=m_keep?(edge_count-out_index):32'd0;
    assign m_edges=m_keep?edge_count:32'd0;
    assign m_has_edge=m_keep && out_index!=edge_count;
    assign m_error=out_error;
    assign m_tag=tag;
    // Each bank has synchronous read data and at most one access per clock.
    // Payload RAM is never reset; per-command counts and used bits own all reads.
    always @(posedge clk)begin
        if(!rst)begin
            if(state==LOAD && s_valid && s_keep && edge_count<MAX_EDGES)
                edges[edge_count[E-1:0]] <= (s_from<NUM_NODES && s_to<NUM_NODES)?{s_from[V-1:0],s_to[V-1:0]}:{2*V{1'b0}};
            if(state==SCAN_READ)edge_q<=edges[scan];
            else if(state==EDGE_READ)edge_q<=edges[verify_edge];
            if(state==PUSH)stack[sp[E-1:0]]<={cur,cur_in};
            else if(state==POP_READ)stack_q<=stack[sp[E-1:0]];
            if(state==APPEND)route[route_count]<={cur,cur_in};
            else if(state==VERIFY_READ)route_q<=route[verify_index];
            else if(state==OUT_READ)route_q<=route[out_index];
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;used<=0;edge_count<=0;used_count<=0;sp<=0;
            verify_index<=0;out_index<=0;route_count<=0;scan<=0;cur_in<=0;
            verify_edge<=0;out_edge<=0;start_node<=0;cur<=0;previous<=0;
            next_node<=0;out_node<=0;tag<=0;input_error<=0;out_error<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                tag<=c_tag;start_node<=(c_start<NUM_NODES)?c_start[V-1:0]:{V{1'b0}};
                input_error<=(c_start<NUM_NODES)?4'd0:4'd1;
                edge_count<=0;out_error<=0;out_node<=0;out_edge<=0;state<=LOAD;
            end
            LOAD:if(s_valid)begin
                input_error<=row_error;
                if(s_keep && edge_count<MAX_EDGES)edge_count<=edge_count+1'b1;
                if(s_last)begin
                    if(row_error!=0)begin
                        out_error<=row_error;out_node<=0;out_edge<=0;state<=HOLD;
                    end else state<=INIT;
                end
            end
            INIT:begin
                used<=0;used_count<=0;sp<=0;route_count<=0;cur<=start_node;cur_in<=0;scan<=0;
                if(edge_count==0)state<=APPEND;else state<=SCAN_READ;
            end
            SCAN_READ:state<=SCAN_USE;
            SCAN_USE:begin
                if(!used[scan] && edge_q[2*V-1:V]==cur)begin
                    used[scan]<=1'b1;used_count<=used_count+1'b1;state<=PUSH;
                end else if({1'b0,scan}+1'b1==edge_count)state<=APPEND;
                else begin scan<=scan+1'b1;state<=SCAN_READ;end
            end
            PUSH:begin
                sp<=sp+1'b1;cur<=edge_q[V-1:0];cur_in<=scan;scan<=0;state<=SCAN_READ;
            end
            APPEND:begin
                route_count<=route_count+1'b1;
                if(sp==0)state<=CHECK;
                else begin sp<=sp-1'b1;state<=POP_READ;end
            end
            POP_READ:state<=POP_USE;
            POP_USE:begin cur<=stack_q[V+E-1:E];cur_in<=stack_q[E-1:0];scan<=0;state<=SCAN_READ;end
            CHECK:begin
                if(used_count!=edge_count || route_count!=({1'b0,edge_count}+1'b1))begin
                    out_error<=4'd8;out_node<=0;out_edge<=0;state<=HOLD;
                end else begin verify_index<=edge_count;state<=VERIFY_READ;end
            end
            VERIFY_READ:state<=VERIFY_USE;
            VERIFY_USE:begin
                if(verify_index==edge_count)begin
                    previous<=route_q[V+E-1:E];
                    if(route_q[V+E-1:E]!=start_node)begin
                        out_error<=4'd8;out_node<=0;out_edge<=0;state<=HOLD;
                    end else if(verify_index==0)begin out_index<=edge_count;state<=OUT_READ;end
                    else begin verify_index<=verify_index-1'b1;state<=VERIFY_READ;end
                end else begin
                    next_node<=route_q[V+E-1:E];verify_edge<=route_q[E-1:0];state<=EDGE_READ;
                end
            end
            EDGE_READ:state<=EDGE_USE;
            EDGE_USE:begin
                if(edge_q[2*V-1:V]!=previous || edge_q[V-1:0]!=next_node)begin
                    out_error<=4'd8;out_node<=0;out_edge<=0;state<=HOLD;
                end else begin
                    previous<=next_node;
                    if(verify_index==0)begin out_index<=edge_count;state<=OUT_READ;end
                    else begin verify_index<=verify_index-1'b1;state<=VERIFY_READ;end
                end
            end
            OUT_READ:state<=OUT_USE;
            OUT_USE:begin
                out_node<=route_q[V+E-1:E];out_edge<=(out_index==edge_count)?{E{1'b0}}:route_q[E-1:0];state<=HOLD;
            end
            HOLD:if(m_ready)begin
                if(out_error!=0 || out_index==0)state<=IDLE;
                else begin out_index<=out_index-1'b1;state<=OUT_READ;end
            end
        endcase
    end
endmodule
