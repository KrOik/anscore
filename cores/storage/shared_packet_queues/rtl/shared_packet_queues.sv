// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Serialized shared-cell packet ownership, atomic publication and reclamation.
module shared_packet_queues #(
    parameter integer QUEUES=4,CELLS=64,DATA_W=32,TAG_W=8,
    localparam integer IW=(CELLS>1)?$clog2(CELLS):1,
    localparam integer CW=(CELLS>0)?$clog2(CELLS+1):1,
    localparam integer QW=(QUEUES>1)?$clog2(QUEUES):1
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [1:0] s_op, // PUSH packet / POP packet / FLUSH queue / QUERY
    input wire [7:0] s_queue,
    input wire [DATA_W-1:0] s_data,
    input wire s_keep,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [1:0] m_op,output wire [1:0] m_status,
    output reg [7:0] m_queue,output reg [TAG_W-1:0] m_tag,
    output wire m_keep,m_first,m_last,
    output wire [IW-1:0] m_index,
    output wire [DATA_W-1:0] m_data,
    output wire [TAG_W-1:0] m_packet_tag,
    output wire [CW-1:0] m_free_cells,m_queue_cells,m_queue_packets
);
    localparam [3:0] INIT=0,IDLE=1,COLLECT=2,DRAIN=3,ALLOC_READ=4,
        ALLOC_WRITE=5,LINK_PREV=6,COMMIT=7,RECLAIM_READ=8,
        RECLAIM_WRITE=9,POP_READ=10,POP_HOLD=11,ACK=12;
    localparam [1:0] OK=0,EMPTY=1,BAD_QUEUE=2,NO_SPACE=3;
    generate if(QUEUES<1 || QUEUES>16 || CELLS<1 || CELLS>256 ||
        DATA_W<1 || DATA_W>64 || TAG_W<1 || TAG_W>32)begin: bad_parameter
        shared_packet_queues_invalid_parameter__see_README invalid_configuration();
    end endgenerate
    reg [3:0] state;
    reg [IW-1:0] links[0:CELLS-1];
    reg [DATA_W+TAG_W-1:0] payload[0:CELLS-1];
    reg last_bits[0:CELLS-1];
    reg [IW-1:0] q_head[0:QUEUES-1],q_tail[0:QUEUES-1];
    reg [CW-1:0] q_cells[0:QUEUES-1],q_packets[0:QUEUES-1];
    reg [IW-1:0] init_index,free_head,pending_head,pending_tail;
    reg [IW-1:0] new_node,prev_node,walk_node,next_q,out_index;
    reg [CW-1:0] free_count,pending_count,walk_remaining;
    reg [QW-1:0] cmd_queue;
    reg [DATA_W-1:0] captured_data;
    reg captured_last,reclaim_flush,last_q;
    reg [DATA_W+TAG_W-1:0] output_q;
    reg [1:0] push_error,ack_status;
    reg [CW-1:0] ack_free,ack_cells,ack_packets;
    wire [QW-1:0] active_queue=(state==IDLE)?s_queue[QW-1:0]:cmd_queue;
    wire popping=state==POP_HOLD;
    assign s_ready=!rst && (state==IDLE || state==COLLECT || state==DRAIN);
    assign m_valid=!rst && (state==ACK || popping);
    assign m_status=popping?OK:ack_status;
    assign m_keep=popping;
    assign m_first=!popping || out_index==0;
    assign m_last=!popping || last_q;
    assign m_index=popping?out_index:{IW{1'b0}};
    assign m_data=popping?output_q[DATA_W-1:0]:{DATA_W{1'b0}};
    assign m_packet_tag=popping?output_q[DATA_W+:TAG_W]:{TAG_W{1'b0}};
    // POP snapshots describe credits/counts immediately AFTER this token fires.
    // Its cell stays owned by the queue throughout any output stall.
    assign m_free_cells=popping?free_count+1'b1:ack_free;
    assign m_queue_cells=popping?q_cells[cmd_queue]-1'b1:ack_cells;
    assign m_queue_packets=popping?q_packets[cmd_queue]-last_q:ack_packets;

    task acknowledge(input [1:0] status_code,input [CW-1:0] fc,qc,qp);
        begin ack_status<=status_code;ack_free<=fc;ack_cells<=qc;ack_packets<=qp;state<=ACK;end
    endtask
    task finish_rejected;
        begin
            if(pending_count!=0)begin
                walk_node<=pending_head;walk_remaining<=pending_count;
                reclaim_flush<=0;state<=RECLAIM_READ;
            end else acknowledge(push_error,free_count,q_cells[cmd_queue],q_packets[cmd_queue]);
        end
    endtask
    task consume_push;
        begin
            if(s_keep && free_count!=0)begin
                captured_data<=s_data;captured_last<=s_last;state<=ALLOC_READ;
            end else if(s_keep)begin
                push_error<=NO_SPACE;
                if(!s_last)state<=DRAIN;
                else if(pending_count!=0)begin
                    walk_node<=pending_head;walk_remaining<=pending_count;
                    reclaim_flush<=0;state<=RECLAIM_READ;
                end else acknowledge(NO_SPACE,free_count,q_cells[active_queue],q_packets[active_queue]);
            end else if(s_last)begin
                if(pending_count!=0)state<=COMMIT;
                else acknowledge(EMPTY,free_count,q_cells[active_queue],q_packets[active_queue]);
            end else state<=COLLECT;
        end
    endtask

    // Single synchronous link read/write; payload and marker share its schedule.
    // There are no read/write collisions and no payload/marker-array reset.
    always @(posedge clk) if(!rst)begin
        case(state)
            INIT: links[init_index]<=(init_index==CELLS-1)?{IW{1'b0}}:init_index+1'b1;
            ALLOC_READ: next_q<=links[free_head];
            ALLOC_WRITE: begin
                links[free_head]<=0;payload[free_head]<={m_tag,captured_data};last_bits[free_head]<=0;
            end
            LINK_PREV: if(pending_count>1)links[prev_node]<=new_node;
            COMMIT: begin
                last_bits[pending_tail]<=1;
                if(q_cells[cmd_queue]!=0)links[q_tail[cmd_queue]]<=pending_head;
            end
            RECLAIM_READ: next_q<=links[walk_node];
            RECLAIM_WRITE: links[walk_node]<=free_head;
            POP_READ: begin next_q<=links[walk_node];output_q<=payload[walk_node];last_q<=last_bits[walk_node];end
            POP_HOLD: if(m_ready)links[walk_node]<=free_head;
            default: begin end
        endcase
    end
    integer q;
    always @(posedge clk)begin
        if(rst)begin
            state<=INIT;init_index<=0;free_head<=0;free_count<=CELLS;
            pending_head<=0;pending_tail<=0;pending_count<=0;cmd_queue<=0;
            new_node<=0;prev_node<=0;walk_node<=0;walk_remaining<=0;out_index<=0;
            captured_data<=0;captured_last<=0;reclaim_flush<=0;push_error<=0;
            m_op<=0;m_queue<=0;m_tag<=0;ack_status<=0;ack_free<=CELLS;ack_cells<=0;ack_packets<=0;
            for(q=0;q<QUEUES;q=q+1)begin q_head[q]<=0;q_tail[q]<=0;q_cells[q]<=0;q_packets[q]<=0;end
        end else case(state)
            INIT: if(init_index==CELLS-1)state<=IDLE;else init_index<=init_index+1'b1;
            IDLE: if(s_valid)begin
                m_op<=s_op;m_queue<=s_queue;m_tag<=s_tag;out_index<=0;push_error<=0;
                cmd_queue<=s_queue[QW-1:0];
                if(s_queue>=QUEUES)begin
                    push_error<=BAD_QUEUE;
                    if(s_op==0 && !s_last)state<=DRAIN;
                    else acknowledge(BAD_QUEUE,free_count,0,0);
                end else case(s_op)
                    0:consume_push();
                    1:if(q_packets[active_queue]==0)acknowledge(EMPTY,free_count,q_cells[active_queue],q_packets[active_queue]);
                      else begin walk_node<=q_head[active_queue];state<=POP_READ;end
                    2:if(q_cells[active_queue]==0)acknowledge(OK,free_count,0,0);
                      else begin walk_node<=q_head[active_queue];walk_remaining<=q_cells[active_queue];reclaim_flush<=1;state<=RECLAIM_READ;end
                    3:acknowledge(OK,free_count,q_cells[active_queue],q_packets[active_queue]);
                endcase
            end
            COLLECT: if(s_valid)consume_push();
            DRAIN: if(s_valid && s_last)begin
                if(push_error==BAD_QUEUE)acknowledge(BAD_QUEUE,free_count,0,0);
                else finish_rejected();
            end
            ALLOC_READ: state<=ALLOC_WRITE;
            ALLOC_WRITE: begin
                new_node<=free_head;prev_node<=pending_tail;
                if(pending_count==0)pending_head<=free_head;
                pending_tail<=free_head;pending_count<=pending_count+1'b1;
                free_head<=next_q;free_count<=free_count-1'b1;state<=LINK_PREV;
            end
            LINK_PREV: if(captured_last)state<=COMMIT;else state<=COLLECT;
            COMMIT: begin
                if(q_cells[cmd_queue]==0)q_head[cmd_queue]<=pending_head;
                q_tail[cmd_queue]<=pending_tail;
                q_cells[cmd_queue]<=q_cells[cmd_queue]+pending_count;
                q_packets[cmd_queue]<=q_packets[cmd_queue]+1'b1;
                acknowledge(OK,free_count,q_cells[cmd_queue]+pending_count,q_packets[cmd_queue]+1'b1);
            end
            RECLAIM_READ: state<=RECLAIM_WRITE;
            RECLAIM_WRITE: begin
                free_head<=walk_node;free_count<=free_count+1'b1;
                if(walk_remaining==1)begin
                    if(reclaim_flush)begin
                        q_head[cmd_queue]<=0;q_tail[cmd_queue]<=0;q_cells[cmd_queue]<=0;q_packets[cmd_queue]<=0;
                        acknowledge(OK,free_count+1'b1,0,0);
                    end else acknowledge(push_error,free_count+1'b1,q_cells[cmd_queue],q_packets[cmd_queue]);
                end else begin walk_node<=next_q;walk_remaining<=walk_remaining-1'b1;state<=RECLAIM_READ;end
            end
            POP_READ: state<=POP_HOLD;
            POP_HOLD: if(m_ready)begin
                free_head<=walk_node;free_count<=free_count+1'b1;
                q_cells[cmd_queue]<=q_cells[cmd_queue]-1'b1;
                q_head[cmd_queue]<=next_q;
                if(last_q)begin
                    q_packets[cmd_queue]<=q_packets[cmd_queue]-1'b1;
                    if(q_cells[cmd_queue]==1)begin q_head[cmd_queue]<=0;q_tail[cmd_queue]<=0;end
                    state<=IDLE;
                end else begin walk_node<=next_q;out_index<=out_index+1'b1;state<=POP_READ;end
            end
            ACK: if(m_ready)begin pending_count<=0;state<=IDLE;end
            default: state<=INIT;
        endcase
    end
endmodule
