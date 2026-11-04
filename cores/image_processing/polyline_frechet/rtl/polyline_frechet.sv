// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
// Exact ordered-curve bottleneck distance and a reverse optimal coupling.
module polyline_frechet #(
    parameter integer COORD_W=12,MAX_POINTS=16,TAG_W=8,
    localparam integer IW=($clog2(MAX_POINTS)<1)?1:$clog2(MAX_POINTS),
    localparam integer CW=($clog2(MAX_POINTS+1)<1)?1:$clog2(MAX_POINTS+1),
    localparam integer DW=2*COORD_W+1
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_a_x,s_a_y,s_b_x,s_b_y,
    input wire s_a_keep,s_b_keep,s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [COORD_W-1:0] m_a_x,m_a_y,m_b_x,m_b_y,
    output reg [IW-1:0] m_index_a,m_index_b,
    output reg [CW-1:0] m_count_a,m_count_b,
    output reg [DW-1:0] m_distance_sq,
    output reg m_first,output wire m_last,m_empty,
    output reg [3:0] m_errors,output reg [TAG_W-1:0] m_tag
);
    localparam integer GOOD=COORD_W>=2 && COORD_W<=24 && MAX_POINTS>=1 && MAX_POINTS<=32,
        N=GOOD?MAX_POINTS:1,TW=($clog2(N*N)<1)?1:$clog2(N*N),
        BW=($clog2(COORD_W)<1)?1:$clog2(COORD_W);
    localparam [3:0] CAPTURE=0,CHECK=1,CELL_READ=2,CELL_SETUP=3,MUL_X=4,
        Y_SETUP=5,MUL_Y=6,CELL_STORE=7,TRACE_READ=8,TRACE_LOAD=9,EMIT=10;
    localparam [1:0] ORIGIN=0,DIAGONAL=1,UP=2,LEFT=3;
    reg [3:0] state;
    reg started;
    reg [IW-1:0] i,j;
    reg [TW-1:0] trace_address;
    reg [2*COORD_W-1:0] points_a[0:N-1],points_b[0:N-1],a_q,b_q;
    reg [DW-1:0] row[0:N-1],row_q,left_value,diagonal_value,minimum,distance_sq;
    reg [1:0] trace[0:N*N-1],trace_q,predecessor;
    reg [COORD_W-1:0] y_magnitude,multiplier;
    reg [2*COORD_W-1:0] multiplicand,accumulator,x_square;
    reg [BW-1:0] bit_index;
    wire signed [COORD_W:0] dx=$signed({a_q[2*COORD_W-1],a_q[2*COORD_W-1:COORD_W]})-
        $signed({b_q[2*COORD_W-1],b_q[2*COORD_W-1:COORD_W]});
    wire signed [COORD_W:0] dy=$signed({a_q[COORD_W-1],a_q[COORD_W-1:0]})-
        $signed({b_q[COORD_W-1],b_q[COORD_W-1:0]});
    wire [COORD_W:0] abs_dx=dx[COORD_W] ? -dx : dx;
    wire [COORD_W:0] abs_dy=dy[COORD_W] ? -dy : dy;
    wire [2*COORD_W-1:0] multiply_total=accumulator+(multiplier[0]?multiplicand:{(2*COORD_W){1'b0}});
    wire [DW-1:0] cell_value=(distance_sq>minimum)?distance_sq:minimum;
    reg [DW-1:0] selected_minimum;
    reg [1:0] selected_predecessor;
    always @* begin
        selected_minimum=0;selected_predecessor=ORIGIN;
        if(i==0 && j!=0)begin selected_minimum=left_value;selected_predecessor=LEFT;end
        else if(i!=0 && j==0)begin selected_minimum=row_q;selected_predecessor=UP;end
        else if(i!=0 && j!=0)begin
            // Strict updates implement diagonal, up, left priority on ties.
            selected_minimum=diagonal_value;selected_predecessor=DIAGONAL;
            if(row_q<selected_minimum)begin selected_minimum=row_q;selected_predecessor=UP;end
            if(left_value<selected_minimum)begin selected_minimum=left_value;selected_predecessor=LEFT;end
        end
    end
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==EMIT;
    assign m_empty=|m_errors;
    assign m_last=m_empty || (m_index_a==0 && m_index_b==0);

    // Each bank has one scheduled synchronous read. Capture, DP and trace
    // ownership are disjoint; no read/write collision or reset sweep is needed.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid && s_ready)begin
            if(s_a_keep && m_count_a<N)points_a[m_count_a]<={s_a_x,s_a_y};
            if(s_b_keep && m_count_b<N)points_b[m_count_b]<={s_b_x,s_b_y};
        end
        if(state==CELL_READ || state==TRACE_READ)begin a_q<=points_a[i];b_q<=points_b[j];end
        if(state==CELL_READ)row_q<=row[j];
        if(state==TRACE_READ)trace_q<=trace[trace_address];
        if(state==CELL_STORE)begin row[j]<=cell_value;trace[trace_address]<=predecessor;end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;started<=0;i<=0;j<=0;trace_address<=0;
            left_value<=0;diagonal_value<=0;minimum<=0;distance_sq<=0;predecessor<=ORIGIN;
            y_magnitude<=0;multiplier<=0;multiplicand<=0;accumulator<=0;x_square<=0;bit_index<=0;
            m_a_x<=0;m_a_y<=0;m_b_x<=0;m_b_y<=0;m_index_a<=0;m_index_b<=0;
            m_count_a<=0;m_count_b<=0;m_distance_sq<=0;m_first<=0;m_errors<=0;m_tag<=0;
        end else case(state)
            CAPTURE:if(s_valid && s_ready)begin
                if(!started)begin m_tag<=s_tag;started<=1;end
                if(s_a_keep)begin
                    if(m_count_a<N)m_count_a<=m_count_a+1'b1;else m_errors[2]<=1;
                end
                if(s_b_keep)begin
                    if(m_count_b<N)m_count_b<=m_count_b+1'b1;else m_errors[3]<=1;
                end
                if(s_last)state<=CHECK;
            end
            CHECK:begin
                m_errors<={m_errors[3:2],m_count_b==0,m_count_a==0};
                m_a_x<=0;m_a_y<=0;m_b_x<=0;m_b_y<=0;m_index_a<=0;m_index_b<=0;m_distance_sq<=0;
                if(m_errors[3:2]!=0 || m_count_a==0 || m_count_b==0)begin m_first<=1;state<=EMIT;end
                else begin i<=0;j<=0;trace_address<=0;left_value<=0;diagonal_value<=0;state<=CELL_READ;end
            end
            CELL_READ:state<=CELL_SETUP;
            CELL_SETUP:begin
                minimum<=selected_minimum;predecessor<=selected_predecessor;
                y_magnitude<=abs_dy[COORD_W-1:0];multiplier<=abs_dx[COORD_W-1:0];
                multiplicand<={{COORD_W{1'b0}},abs_dx[COORD_W-1:0]};accumulator<=0;bit_index<=0;state<=MUL_X;
            end
            MUL_X:begin
                if(bit_index==COORD_W-1)begin x_square<=multiply_total;state<=Y_SETUP;end
                else begin accumulator<=multiply_total;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;bit_index<=bit_index+1'b1;end
            end
            Y_SETUP:begin
                multiplier<=y_magnitude;multiplicand<={{COORD_W{1'b0}},y_magnitude};accumulator<=0;bit_index<=0;state<=MUL_Y;
            end
            MUL_Y:begin
                if(bit_index==COORD_W-1)begin distance_sq<={1'b0,x_square}+{1'b0,multiply_total};state<=CELL_STORE;end
                else begin accumulator<=multiply_total;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;bit_index<=bit_index+1'b1;end
            end
            CELL_STORE:begin
                left_value<=cell_value;diagonal_value<=row_q;
                if(i==m_count_a-1'b1 && j==m_count_b-1'b1)begin
                    m_distance_sq<=cell_value;m_first<=1;state<=TRACE_READ;
                end else begin
                    if(j==m_count_b-1'b1)begin
                        i<=i+1'b1;j<=0;trace_address<=trace_address+N-m_count_b+1'b1;
                        left_value<=0;diagonal_value<=0;
                    end else begin j<=j+1'b1;trace_address<=trace_address+1'b1;end
                    state<=CELL_READ;
                end
            end
            TRACE_READ:state<=TRACE_LOAD;
            TRACE_LOAD:begin
                m_a_x<=a_q[2*COORD_W-1:COORD_W];m_a_y<=a_q[COORD_W-1:0];
                m_b_x<=b_q[2*COORD_W-1:COORD_W];m_b_y<=b_q[COORD_W-1:0];
                m_index_a<=i;m_index_b<=j;state<=EMIT;
            end
            EMIT:if(m_ready)begin
                if(m_last)begin
                    state<=CAPTURE;started<=0;m_count_a<=0;m_count_b<=0;m_errors<=0;m_tag<=0;m_first<=0;
                end else begin
                    case(trace_q)
                        DIAGONAL:begin i<=i-1'b1;j<=j-1'b1;trace_address<=trace_address-N-1'b1;end
                        UP:begin i<=i-1'b1;trace_address<=trace_address-N;end
                        LEFT:begin j<=j-1'b1;trace_address<=trace_address-1'b1;end
                        default:begin i<=0;j<=0;trace_address<=0;end
                    endcase
                    m_first<=0;state<=TRACE_READ;
                end
            end
            default:state<=CAPTURE;
        endcase
    end
    generate if(!GOOD || TAG_W<1 || TAG_W>32)begin:bad_parameters
        polyline_frechet_invalid_parameters invalid();
    end endgenerate
endmodule
`default_nettype wire
