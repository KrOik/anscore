// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module ram_interval_set #(
    parameter integer MAX_INTERVALS=16, ADDR_W=32, TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid, output wire c_ready,
    input wire [2:0] c_op,
    input wire [63:0] c_base,
    input wire [64:0] c_bytes,
    input wire [TAG_W-1:0] c_tag,
    output wire m_valid, input wire m_ready,
    output wire [2:0] m_op, output reg [2:0] m_status,
    output wire m_keep,m_first,m_last,
    output wire [((MAX_INTERVALS<=2)?1:$clog2(MAX_INTERVALS))-1:0] m_index,
    output wire [ADDR_W-1:0] m_base,
    output wire [ADDR_W:0] m_bytes,
    output wire [$clog2(MAX_INTERVALS+1)-1:0] m_count,
    output wire [ADDR_W:0] m_total,
    output wire [ADDR_W:0] m_covered,
    output wire m_whole,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer I=(MAX_INTERVALS<=2)?1:$clog2(MAX_INTERVALS);
    localparam integer C=$clog2(MAX_INTERVALS+1), R=2*ADDR_W+1;
    localparam [4:0] IDLE=0,VALIDATE=1,START_BUILD=2,BUILD_READ=3,
        BUILD_USE=4,EMIT_CHECK=5,EMIT_WRITE=6,NEXT_ROW=7,BUILD_FINISH=8,
        PUBLISH=9,QUERY_START=10,QUERY_READ=11,QUERY_USE=12,QUERY_DONE=13,
        ENUM_READ=14,ENUM_USE=15,HOLD=16,FAIL=17,SIMPLE=18;
    localparam [2:0] ADD=0,REMOVE=1,COVER=2,ENUM=3,CLEAR=4,STATUS=5;
    localparam [2:0] OK=0,EMPTY=1,BAD_RANGE=2,FULL=3,BAD_OP=4;
    localparam [65:0] DOMAIN=(66'd1<<ADDR_W);
    reg [R-1:0] ram[0:2*MAX_INTERVALS-1];
    reg [R-1:0] read_q,emit_first;
    reg [4:0] state;
    reg active_bank,m_valid_q,pending_valid,second_valid,finish_emit;
    reg [C-1:0] active_count,private_count;
    reg [I-1:0] scan_index;
    reg [ADDR_W:0] active_total,private_total,covered_q,emit_bytes_q;
    reg [2:0] op_q,pending_status;
    reg [63:0] base_q;
    reg [64:0] bytes_q;
    reg [TAG_W-1:0] tag_q;
    wire [ADDR_W-1:0] span_lo=base_q[ADDR_W-1:0];
    reg [ADDR_W-1:0] pending_lo;
    reg [ADDR_W:0] span_end,pending_end;
    wire [ADDR_W-1:0] row_lo=read_q[ADDR_W+1+:ADDR_W];
    wire [ADDR_W:0] row_end=read_q[ADDR_W:0];
    wire [ADDR_W-1:0] emit_lo=emit_first[ADDR_W+1+:ADDR_W];
    wire [ADDR_W:0] emit_end=emit_first[ADDR_W:0];
    wire [65:0] full_base={2'b0,base_q};
    wire [65:0] full_end={2'b0,base_q}+{1'b0,bytes_q};
    wire bad_range=(full_base>=DOMAIN || bytes_q==0 || full_end>DOMAIN);
    wire [ADDR_W:0] overlap_lo=({1'b0,row_lo}>{1'b0,span_lo})?{1'b0,row_lo}:{1'b0,span_lo};
    wire [ADDR_W:0] overlap_end=(row_end<span_end)?row_end:span_end;
    wire [ADDR_W:0] overlap_bytes=(overlap_end>overlap_lo)?overlap_end-overlap_lo:{(ADDR_W+1){1'b0}};
    assign c_ready=!rst && state==IDLE;
    assign m_valid=!rst && m_valid_q;
    assign m_op=op_q;
    assign m_tag=tag_q;
    assign m_count=active_count;
    assign m_total=active_total;
    // The read/counter registers are frozen throughout HOLD. Summary geometry
    // is masked to zero; these aliases avoid duplicating a complete RAM row.
    assign m_keep=(op_q==ENUM && m_status==OK && active_count!=0);
    assign m_first=!m_keep || scan_index==0;
    assign m_last=!m_keep || scan_index+1'b1==active_count;
    assign m_index=m_keep?scan_index:{I{1'b0}};
    assign m_base=m_keep?row_lo:{ADDR_W{1'b0}};
    assign m_bytes=m_keep?(row_end-{1'b0,row_lo}):{(ADDR_W+1){1'b0}};
    assign m_covered=(op_q==COVER && m_status==OK)?covered_q:{(ADDR_W+1){1'b0}};
    assign m_whole=(op_q==COVER && m_status==OK && {{(64-ADDR_W){1'b0}},covered_q}==bytes_q);
    generate if(MAX_INTERVALS<1 || MAX_INTERVALS>64 || ADDR_W<1 || ADDR_W>64 || TAG_W<1 || TAG_W>32) begin:bad
        ram_interval_set_invalid_parameters__see_README illegal_parameters();
    end endgenerate
    // Only these scheduled states access the single synchronous payload port.
    // Reset and CLEAR hide old rows by metadata; neither resets payload RAM.
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;active_bank<=0;active_count<=0;active_total<=0;
            m_valid_q<=0;m_status<=OK;
            op_q<=0;tag_q<=0;
        end else begin
            case(state)
            IDLE: if(c_valid) begin
                op_q<=c_op;base_q<=c_base;bytes_q<=c_bytes;tag_q<=c_tag;
                m_valid_q<=0;state<=VALIDATE;
            end
            VALIDATE: begin
                case(op_q)
                ADD,REMOVE,COVER: if(bad_range) begin pending_status<=BAD_RANGE;state<=FAIL;end
                    else begin
                        span_end<=full_end[ADDR_W:0];
                        if(op_q==COVER) state<=QUERY_START;else state<=START_BUILD;
                    end
                ENUM: begin scan_index<=0;if(active_count==0) state<=SIMPLE;else state<=ENUM_READ;end
                CLEAR,STATUS: state<=SIMPLE;
                default: begin pending_status<=BAD_OP;state<=FAIL;end
                endcase
            end
            START_BUILD: begin
                private_count<=0;private_total<=0;scan_index<=0;
                pending_valid<=(op_q==ADD);pending_lo<=span_lo;pending_end<=span_end;
                if(active_count==0) state<=BUILD_FINISH;else state<=BUILD_READ;
            end
            BUILD_READ: begin read_q<=ram[active_bank?MAX_INTERVALS+scan_index:scan_index];state<=BUILD_USE;end
            BUILD_USE: begin
                second_valid<=0;finish_emit<=0;
                if(op_q==ADD) begin
                    if(!pending_valid) begin emit_first<=read_q;state<=EMIT_CHECK;end
                    else if(row_end<{1'b0,pending_lo}) begin emit_first<=read_q;state<=EMIT_CHECK;end
                    else if(pending_end<{1'b0,row_lo}) begin
                        emit_first<={pending_lo,pending_end};
                        second_valid<=1;pending_valid<=0;state<=EMIT_CHECK;
                    end else begin
                        if(row_lo<pending_lo) pending_lo<=row_lo;
                        if(row_end>pending_end) pending_end<=row_end;
                        state<=NEXT_ROW;
                    end
                end else begin
                    if(row_end<={1'b0,span_lo} || {1'b0,row_lo}>=span_end) begin
                        emit_first<=read_q;state<=EMIT_CHECK;
                    end else if(row_lo<span_lo) begin
                        emit_first<={row_lo,{1'b0,span_lo}};
                        if(row_end>span_end) begin
                            second_valid<=1;
                        end
                        state<=EMIT_CHECK;
                    end else if(row_end>span_end) begin
                        emit_first<={span_end[ADDR_W-1:0],row_end};state<=EMIT_CHECK;
                    end else state<=NEXT_ROW;
                end
            end
            EMIT_CHECK: if(private_count==MAX_INTERVALS) begin pending_status<=FULL;state<=FAIL;end
                else begin emit_bytes_q<=emit_end-{1'b0,emit_lo};state<=EMIT_WRITE;end
            EMIT_WRITE: begin
                ram[active_bank?private_count:MAX_INTERVALS+private_count]<=emit_first;
                private_count<=private_count+1'b1;
                private_total<=private_total+emit_bytes_q;
                if(second_valid) begin
                    emit_first<=(op_q==ADD)?read_q:{span_end[ADDR_W-1:0],row_end};
                    second_valid<=0;state<=EMIT_CHECK;
                end else if(finish_emit) state<=PUBLISH;else state<=NEXT_ROW;
            end
            NEXT_ROW: if(scan_index+1'b1==active_count) state<=BUILD_FINISH;
                else begin scan_index<=scan_index+1'b1;state<=BUILD_READ;end
            BUILD_FINISH: if(pending_valid) begin
                emit_first<={pending_lo,pending_end};second_valid<=0;
                finish_emit<=1;pending_valid<=0;state<=EMIT_CHECK;
            end else state<=PUBLISH;
            PUBLISH: begin
                active_bank<=!active_bank;active_count<=private_count;active_total<=private_total;
                m_valid_q<=1;m_status<=OK;state<=HOLD;
            end
            QUERY_START: begin
                scan_index<=0;covered_q<=0;
                if(active_count==0) state<=QUERY_DONE;else state<=QUERY_READ;
            end
            QUERY_READ: begin read_q<=ram[active_bank?MAX_INTERVALS+scan_index:scan_index];state<=QUERY_USE;end
            QUERY_USE: begin
                covered_q<=covered_q+overlap_bytes;
                if(scan_index+1'b1==active_count) state<=QUERY_DONE;
                else begin scan_index<=scan_index+1'b1;state<=QUERY_READ;end
            end
            QUERY_DONE: begin
                m_valid_q<=1;m_status<=OK;state<=HOLD;
            end
            ENUM_READ: begin read_q<=ram[active_bank?MAX_INTERVALS+scan_index:scan_index];state<=ENUM_USE;end
            ENUM_USE: begin
                m_valid_q<=1;m_status<=OK;state<=HOLD;
            end
            HOLD: if(m_valid_q && m_ready) begin
                m_valid_q<=0;
                if(op_q==ENUM && !m_last) begin scan_index<=scan_index+1'b1;state<=ENUM_READ;end
                else state<=IDLE;
            end
            FAIL: begin
                m_valid_q<=1;m_status<=pending_status;state<=HOLD;
            end
            SIMPLE: begin
                if(op_q==CLEAR) begin active_bank<=0;active_count<=0;active_total<=0;end
                m_valid_q<=1;m_status<=(op_q==ENUM)?EMPTY:OK;state<=HOLD;
            end
            default: state<=IDLE;
            endcase
        end
    end
endmodule
