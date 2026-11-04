// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Original fixed-pool buddy metadata service; no payload memory is instantiated.
module buddy_pool_allocator #(
    parameter integer MAX_ORDER = 6,
    parameter integer TAG_W = 8
)(
    input wire clk, rst,
    input wire s_valid,
    output wire s_ready,
    input wire [1:0] s_op,       // 0 allocate, 1 release, 2 clear, 3 query
    input wire [3:0] s_order,    // block size = 2**order basic units
    input wire [31:0] s_base,    // release address, in basic units
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output reg [1:0] m_op, m_status,
    output reg [3:0] m_order,
    output reg [31:0] m_base,
    output reg [TAG_W-1:0] m_tag,
    output reg [MAX_ORDER:0] m_free_units,
    output reg m_has_free,
    output reg [3:0] m_largest_order
);
    // Safe elaboration dimensions do not make illegal configurations legal.
    localparam integer M = (MAX_ORDER >= 0 && MAX_ORDER <= 10) ? MAX_ORDER : 0;
    localparam integer UNITS = 1 << M;
    localparam integer NODES = 2*UNITS-1;
    localparam integer IW = (M+1 > 1) ? M+1 : 1;
    localparam integer OW = ($clog2(M+2) > 1) ? $clog2(M+2) : 1;
    localparam integer NW = OW+2;
    localparam [1:0] FREE=0, ALLOC=1, SPLIT=2;
    localparam [OW-1:0] ROOT_AVAIL = M+1;
    localparam [3:0] IDLE=0, NODE_READ=1, NODE_CHECK=2,
        LEFT_READ=3, LEFT_CHECK=4, SPLIT_PARENT=5, SPLIT_LEFT=6,
        SPLIT_RIGHT=7, ALLOC_MARK=8, FREE_MARK=9, UP_LEFT_READ=10,
        UP_LEFT_SAVE=11, UP_RIGHT_READ=12, UP_COMMIT=13,
        CLEAR_ROOT=14, RESPONSE=15;
    generate if (MAX_ORDER<0 || MAX_ORDER>10 || TAG_W<1 || TAG_W>32) begin: bad_parameter
        buddy_pool_allocator_invalid_parameter__see_README invalid();
    end endgenerate

    reg [3:0] state;
    reg [1:0] cmd_op;
    reg [3:0] cmd_order;
    reg [31:0] cmd_base;
    reg [IW-1:0] cur;
    reg [3:0] cur_order;
    reg [31:0] cur_base;
    reg [M:0] free_units;
    reg [NW-1:0] tree [0:NODES-1];
    reg [NW-1:0] node_q, left_q;
    wire [IW-1:0] parent = (cur-1'b1) >> 1;
    wire [IW-1:0] child_left = (cur << 1)+1'b1;
    wire [IW-1:0] child_right = (cur << 1)+2'd2;
    wire [IW-1:0] parent_left = (parent << 1)+1'b1;
    wire [IW-1:0] parent_right = (parent << 1)+2'd2;
    wire [1:0] node_kind = node_q[NW-1:OW];
    wire [OW-1:0] node_avail = node_q[OW-1:0];
    wire [OW-1:0] up_avail = (left_q[OW-1:0] > node_avail) ? left_q[OW-1:0] : node_avail;
    wire up_free = left_q[NW-1:OW]==FREE && node_kind==FREE;
    wire [OW-1:0] merged_avail = up_free ? cur_order+2'd2 : up_avail;
    wire [NW-1:0] merged_node = {up_free ? FREE : SPLIT, merged_avail};
    wire [31:0] request_size = 32'd1 << s_order;
    wire [M:0] block_units = {{M{1'b0}},1'b1} << cmd_order;
    wire [OW-1:0] child_avail = cur_order;
    wire [OW-1:0] current_avail = cur_order+1'b1;
    wire [3:0] next_order = cur_order-1'b1;
    wire [31:0] half_units = 32'd1 << next_order;

    reg mem_re, mem_we;
    reg [IW-1:0] mem_raddr, mem_waddr;
    reg [NW-1:0] mem_wdata;
    // One synchronous read port and one write port. No node-array reset.
    always @* begin
        mem_re=0; mem_we=0; mem_raddr=cur; mem_waddr=cur; mem_wdata=0;
        case (state)
            NODE_READ: mem_re=1;
            LEFT_READ: begin mem_re=1;mem_raddr=child_left;end
            SPLIT_PARENT: begin mem_we=1;mem_wdata={SPLIT,current_avail};end
            SPLIT_LEFT: begin mem_we=1;mem_waddr=child_left;mem_wdata={FREE,child_avail};end
            SPLIT_RIGHT: begin mem_we=1;mem_waddr=child_right;mem_wdata={FREE,child_avail};end
            ALLOC_MARK: begin mem_we=1;mem_wdata={ALLOC,{OW{1'b0}}};end
            FREE_MARK: begin mem_we=1;mem_wdata={FREE,current_avail};end
            UP_LEFT_READ: begin mem_re=1;mem_raddr=parent_left;end
            UP_RIGHT_READ: begin mem_re=1;mem_raddr=parent_right;end
            UP_COMMIT: begin mem_we=1;mem_waddr=parent;mem_wdata=merged_node;end
            CLEAR_ROOT: begin mem_we=1;mem_waddr=0;mem_wdata={FREE,ROOT_AVAIL};end
            default: begin end
        endcase
        // Reset interrupts any partial split/update and makes its children unreachable.
        if (rst) begin mem_re=0;mem_we=1;mem_waddr=0;mem_wdata={FREE,ROOT_AVAIL};end
    end
    always @(posedge clk) begin
        if (mem_we) tree[mem_waddr] <= mem_wdata;
        if (mem_re) node_q <= tree[mem_raddr];
    end
    assign s_ready = !rst && state==IDLE;
    assign m_valid = !rst && state==RESPONSE;

    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE;cmd_op<=0;cmd_order<=0;cmd_base<=0;
            cur<=0;cur_order<=M;cur_base<=0;free_units<=UNITS;
            m_op<=0;m_status<=0;m_order<=0;m_base<=0;m_tag<=0;
            m_free_units<=UNITS;m_has_free<=1;m_largest_order<=M;
        end else begin
            case (state)
                IDLE: if (s_valid) begin
                    cmd_op<=s_op;cmd_order<=s_order;cmd_base<=s_base;
                    m_op<=s_op;m_order<=s_order;m_tag<=s_tag;
                    m_status<=0;m_base<=0;m_free_units<=free_units;
                    cur<=0;cur_order<=M;cur_base<=0;
                    // Query and clear ignore both geometry fields.
                    if (s_op==2) state<=CLEAR_ROOT;
                    else if ((s_op==0 || s_op==1) &&
                        (s_order>M || (s_op==1 &&
                        (s_base>=UNITS || (s_base & (request_size-1'b1))!=0)))) begin
                        m_status<=2;state<=NODE_READ;
                    end else state<=NODE_READ;
                end
                NODE_READ: state<=NODE_CHECK;
                NODE_CHECK: begin
                    if (cur==0) begin
                        m_has_free<=node_avail!=0;
                        m_largest_order<=(node_avail!=0) ? node_avail-1'b1 : 0;
                    end
                    if (m_status!=0 || cmd_op==3) state<=RESPONSE;
                    else if (cmd_op==0) begin
                        if (node_avail < cmd_order+1'b1) begin
                            m_status<=1;state<=RESPONSE;
                        end else if (cur_order==cmd_order) state<=ALLOC_MARK;
                        else if (node_kind==FREE) state<=SPLIT_PARENT;
                        else state<=LEFT_READ;
                    end else begin
                        if (cur_order==cmd_order) begin
                            if (node_kind==ALLOC) state<=FREE_MARK;
                            else begin m_status<=3;state<=RESPONSE;end
                        end else if (node_kind!=SPLIT) begin
                            m_status<=3;state<=RESPONSE;
                        end else begin
                            cur_order<=next_order;
                            if ((cmd_base & half_units)!=0) begin
                                cur<=child_right;cur_base<=cur_base+half_units;
                            end else cur<=child_left;
                            state<=NODE_READ;
                        end
                    end
                end
                LEFT_READ: state<=LEFT_CHECK;
                LEFT_CHECK: begin
                    cur_order<=next_order;
                    if (node_avail >= cmd_order+1'b1) begin
                        cur<=child_left;state<=NODE_CHECK;
                    end else begin
                        cur<=child_right;cur_base<=cur_base+half_units;
                        state<=NODE_READ;
                    end
                end
                SPLIT_PARENT: state<=SPLIT_LEFT;
                SPLIT_LEFT: state<=SPLIT_RIGHT;
                SPLIT_RIGHT: begin
                    cur<=child_left;cur_order<=next_order;state<=NODE_READ;
                end
                ALLOC_MARK: begin
                    m_base<=cur_base;free_units<=free_units-block_units;
                    m_free_units<=free_units-block_units;
                    if (cur==0) begin m_has_free<=0;m_largest_order<=0;state<=RESPONSE;end
                    else state<=UP_LEFT_READ;
                end
                FREE_MARK: begin
                    m_base<=cmd_base;free_units<=free_units+block_units;
                    m_free_units<=free_units+block_units;
                    if (cur==0) begin m_has_free<=1;m_largest_order<=M;state<=RESPONSE;end
                    else state<=UP_LEFT_READ;
                end
                UP_LEFT_READ: state<=UP_LEFT_SAVE;
                UP_LEFT_SAVE: begin left_q<=node_q;state<=UP_RIGHT_READ;end
                UP_RIGHT_READ: state<=UP_COMMIT;
                UP_COMMIT: begin
                    cur<=parent;cur_order<=cur_order+1'b1;
                    if (parent==0) begin
                        m_has_free<=merged_avail!=0;
                        m_largest_order<=(merged_avail!=0) ? merged_avail-1'b1 : 0;
                        state<=RESPONSE;
                    end else state<=UP_LEFT_READ;
                end
                CLEAR_ROOT: begin
                    free_units<=UNITS;m_free_units<=UNITS;
                    m_has_free<=1;m_largest_order<=M;state<=RESPONSE;
                end
                RESPONSE: if (m_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
