// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module binary_hausdorff #(
    parameter integer WIDTH=16,HEIGHT=12,TAG_W=8,
    localparam integer X_W=($clog2(WIDTH)<1)?1:$clog2(WIDTH),
    localparam integer Y_W=($clog2(HEIGHT)<1)?1:$clog2(HEIGHT),
    localparam integer COUNT_W=($clog2(WIDTH*HEIGHT+1)<1)?1:$clog2(WIDTH*HEIGHT+1),
    localparam integer DIST_W=($clog2((WIDTH-1)*(WIDTH-1)+(HEIGHT-1)*(HEIGHT-1)+1)<1)?1:
        $clog2((WIDTH-1)*(WIDTH-1)+(HEIGHT-1)*(HEIGHT-1)+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire s_a,s_b,s_sof,s_eol,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [COUNT_W-1:0] m_count_a,m_count_b,
    output reg [DIST_W-1:0] m_ab_distance_sq,m_ba_distance_sq,
    output wire [DIST_W-1:0] m_distance_sq,output wire m_direction,
    output reg [X_W-1:0] m_ab_source_x,m_ab_target_x,m_ba_source_x,m_ba_target_x,
    output reg [Y_W-1:0] m_ab_source_y,m_ab_target_y,m_ba_source_y,m_ba_target_y,
    output reg [TAG_W-1:0] m_tag,output reg [3:0] m_errors
);
    localparam integer GOOD=WIDTH>=1 && WIDTH<=32 && HEIGHT>=1 && HEIGHT<=32,
        N=GOOD?WIDTH*HEIGHT:1,AW=($clog2(N)<1)?1:$clog2(N);
    localparam [3:0] BOOT=0,CAPTURE=1,CHECK_FRAME=2,MAP_READ=3,MAP_EVAL=4,
        WAIT_DONE=5,FEED_READ=6,FEED_SEND=7,EMIT=8;
    reg [3:0] state;
    reg phase,ab_seen,ba_seen;
    reg [AW-1:0] capture_index,map_index,feed_index;
    reg [X_W-1:0] capture_x,feed_x;
    reg [1:0] masks[0:N-1],mask_q,framing_errors;
    wire child_ready,child_valid,child_invalid,child_done,child_error;
    wire [31:0] child_distance;
    wire [15:0] child_x,child_y,child_nearest_x,child_nearest_y;
    wire child_sof,child_eol,child_last;
    wire child_reset_n=!rst && state!=BOOT && state!=EMIT;
    wire child_source_valid=!rst && ((state==CAPTURE && s_valid) || state==FEED_SEND);
    wire child_source_pixel=(state==CAPTURE)?!s_b:!mask_q[1];
    wire child_source_sof=(state==CAPTURE)?capture_index==0:feed_index==0;
    wire child_source_eol=(state==CAPTURE)?capture_x==WIDTH-1:feed_x==WIDTH-1;
    wire child_take=!rst && state==MAP_EVAL;
    assign s_ready=!rst && state==CAPTURE && child_ready;
    assign m_valid=!rst && state==EMIT;
    assign m_direction=m_ba_distance_sq>m_ab_distance_sq;
    assign m_distance_sq=m_direction?m_ba_distance_sq:m_ab_distance_sq;
    euclidean_distance #(.WIDTH(GOOD?WIDTH:1),.HEIGHT(GOOD?HEIGHT:1)) edt(
        .clk(clk),.rst_n(child_reset_n),.ce(1'b1),
        .s_pixel(child_source_pixel),.s_valid(child_source_valid),.s_ready(child_ready),
        .s_sof(child_source_sof),.s_eol(child_source_eol),
        .m_valid(child_valid),.m_ready(child_take),.m_distance_squared(child_distance),
        .m_nearest_x(child_nearest_x),.m_nearest_y(child_nearest_y),.m_invalid(child_invalid),
        .m_x(child_x),.m_y(child_y),.m_sof(child_sof),.m_eol(child_eol),.m_last(child_last),
        .done_valid(child_done),.done_ready(state==WAIT_DONE),.done_error(child_error));

    // One synchronous mask read port; capture writes and reads are disjoint.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid && s_ready)masks[capture_index]<={s_a,s_b};
        if(state==MAP_READ && child_valid)mask_q<=masks[map_index];
        if(state==FEED_READ)mask_q<=masks[feed_index];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=BOOT;phase<=0;ab_seen<=0;ba_seen<=0;
            capture_index<=0;map_index<=0;feed_index<=0;capture_x<=0;feed_x<=0;
            framing_errors<=0;m_count_a<=0;m_count_b<=0;m_tag<=0;m_errors<=0;
            m_ab_distance_sq<=0;m_ba_distance_sq<=0;
            m_ab_source_x<=0;m_ab_source_y<=0;m_ab_target_x<=0;m_ab_target_y<=0;
            m_ba_source_x<=0;m_ba_source_y<=0;m_ba_target_x<=0;m_ba_target_y<=0;
        end else case(state)
            BOOT:begin
                state<=CAPTURE;phase<=0;ab_seen<=0;ba_seen<=0;
                capture_index<=0;map_index<=0;feed_index<=0;capture_x<=0;feed_x<=0;
                framing_errors<=0;m_count_a<=0;m_count_b<=0;m_tag<=0;m_errors<=0;
                m_ab_distance_sq<=0;m_ba_distance_sq<=0;
                m_ab_source_x<=0;m_ab_source_y<=0;m_ab_target_x<=0;m_ab_target_y<=0;
                m_ba_source_x<=0;m_ba_source_y<=0;m_ba_target_x<=0;m_ba_target_y<=0;
            end
            CAPTURE:if(s_valid && s_ready)begin
                if(capture_index==0)m_tag<=s_tag;
                m_count_a<=m_count_a+{{(COUNT_W-1){1'b0}},s_a};
                m_count_b<=m_count_b+{{(COUNT_W-1){1'b0}},s_b};
                if(s_sof!=(capture_index==0))framing_errors[0]<=1;
                if(s_eol!=(capture_x==WIDTH-1))framing_errors[1]<=1;
                if(capture_index==N-1)state<=CHECK_FRAME;
                else begin
                    capture_index<=capture_index+1'b1;
                    if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1'b1;
                end
            end
            CHECK_FRAME:begin
                m_errors<={framing_errors,m_count_b==0,m_count_a==0};
                if(framing_errors!=0 || m_count_a==0 || m_count_b==0)state<=EMIT;
                else begin map_index<=0;phase<=0;state<=MAP_READ;end
            end
            MAP_READ:if(child_valid)state<=MAP_EVAL;
            MAP_EVAL:if(child_valid)begin
                if(!phase && mask_q[1])begin
                    if(!ab_seen || child_distance>m_ab_distance_sq)begin
                        m_ab_distance_sq<=child_distance[DIST_W-1:0];
                        m_ab_source_x<=child_x[X_W-1:0];m_ab_source_y<=child_y[Y_W-1:0];
                        m_ab_target_x<=child_nearest_x[X_W-1:0];m_ab_target_y<=child_nearest_y[Y_W-1:0];
                    end
                    ab_seen<=1;
                end
                if(phase && mask_q[0])begin
                    if(!ba_seen || child_distance>m_ba_distance_sq)begin
                        m_ba_distance_sq<=child_distance[DIST_W-1:0];
                        m_ba_source_x<=child_x[X_W-1:0];m_ba_source_y<=child_y[Y_W-1:0];
                        m_ba_target_x<=child_nearest_x[X_W-1:0];m_ba_target_y<=child_nearest_y[Y_W-1:0];
                    end
                    ba_seen<=1;
                end
                if(map_index==N-1)state<=WAIT_DONE;
                else begin map_index<=map_index+1'b1;state<=MAP_READ;end
            end
            WAIT_DONE:if(child_done)begin
                if(!phase)begin phase<=1;feed_index<=0;feed_x<=0;map_index<=0;state<=FEED_READ;end
                else state<=EMIT;
            end
            FEED_READ:state<=FEED_SEND;
            FEED_SEND:if(child_ready)begin
                if(feed_index==N-1)begin map_index<=0;state<=MAP_READ;end
                else begin
                    feed_index<=feed_index+1'b1;
                    if(feed_x==WIDTH-1)feed_x<=0;else feed_x<=feed_x+1'b1;
                    state<=FEED_READ;
                end
            end
            EMIT:if(m_ready)state<=BOOT;
            default:state<=BOOT;
        endcase
    end
    generate if(!GOOD || TAG_W<1 || TAG_W>32)begin:bad_parameters
        binary_hausdorff_invalid_parameters invalid();
    end endgenerate
endmodule
`default_nettype wire
