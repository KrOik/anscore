// SPDX-License-Identifier: Apache-2.0
// Original exact half-level edge intersections and bilinear branch topology.
`timescale 1ns/1ps
module grayscale_isocontour #(
    parameter integer WIDTH=16, HEIGHT=16, PIXEL_W=8, TAG_W=8,
    localparam integer N=WIDTH*HEIGHT,
    localparam integer XW=(WIDTH<2)?1:$clog2(WIDTH),
    localparam integer YW=(HEIGHT<2)?1:$clog2(HEIGHT),
    localparam integer AW=(N<2)?1:$clog2(N),
    localparam integer SEGMENTS=2*(WIDTH-1)*(HEIGHT-1),
    localparam integer SW=(SEGMENTS<1)?1:$clog2(SEGMENTS+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [PIXEL_W-1:0] s_pixel,s_level,
    input wire s_sof,s_eol,s_error,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg m_axis0,output reg [XW-1:0] m_x0,output reg [YW-1:0] m_y0,
    output reg [PIXEL_W:0] m_num0,m_den0,
    output reg m_axis1,output reg [XW-1:0] m_x1,output reg [YW-1:0] m_y1,
    output reg [PIXEL_W:0] m_num1,m_den1,
    output wire [SW-1:0] m_index,output wire m_is_summary,m_first,m_last,
    output wire [2:0] m_errors,output wire [TAG_W-1:0] m_tag
);
    generate if(WIDTH<1 || WIDTH>64 || HEIGHT<1 || HEIGHT>64 ||
                PIXEL_W<1 || PIXEL_W>12 || TAG_W<1 || TAG_W>32)begin:bad
        grayscale_isocontour_invalid_parameters__see_README invalid();
    end endgenerate
    localparam integer DEPTH=(N<1 || N>4096)?1:N;
    localparam integer PW=2*PIXEL_W+4,EW=1+XW+YW+2*(PIXEL_W+1);
    localparam CAPTURE=0,CHECK=1,CELL_START=2,LOAD_READ=3,LOAD_LATCH=4,
        CLASSIFY=5,MUL_A=6,MUL_SAVE=7,MUL_B=8,DECIDE=9,MAKE=10,HOLD=11,
        ADV=12,SUMMARY_PREP=13,SUMMARY_HOLD=14;
    reg [3:0] state;
    // Capture and cell traversal have disjoint lifetimes; share their cursors.
    reg [AW-1:0] address;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg [PIXEL_W-1:0] image_memory[0:DEPTH-1],image_q;
    reg signed [PIXEL_W+1:0] deviation[0:3];
    reg signed [PW-1:0] product_q,first_product;
    reg [1:0] load_slot,edge0,edge1,edge2,edge3;
    reg pair_two,pair_second;
    reg [SW-1:0] segment_count;
    reg [PIXEL_W-1:0] level;
    reg [TAG_W-1:0] tag;
    reg [2:0] errors;
    wire [2:0] incoming_errors={s_error,s_eol!=(x==WIDTH-1),s_sof!=(address==0)};
    wire signed [PIXEL_W+1:0] doubled_sample=$signed({1'b0,image_q,1'b0});
    wire signed [PIXEL_W+1:0] doubled_level=$signed({1'b0,level,1'b1});
    wire [3:0] crossings={deviation[0][PIXEL_W+1]!=deviation[3][PIXEL_W+1],
                          deviation[3][PIXEL_W+1]!=deviation[2][PIXEL_W+1],
                          deviation[1][PIXEL_W+1]!=deviation[2][PIXEL_W+1],
                          deviation[0][PIXEL_W+1]!=deviation[1][PIXEL_W+1]};
    // One natural-width signed multiply, scheduled twice only for four crossings.
    wire signed [PIXEL_W+1:0] mul_a=(state==MUL_B)?deviation[1]:deviation[0];
    wire signed [PIXEL_W+1:0] mul_b=(state==MUL_B)?deviation[3]:deviation[2];
    wire signed [PW-1:0] full_product=mul_a*mul_b;
    wire signed [PW:0] determinant=$signed({first_product[PW-1],first_product})-
                                  $signed({product_q[PW-1],product_q});
    reg [AW-1:0] read_address;
    always @* begin
        read_address=address;
        case(load_slot)
            1:read_address=address+1'b1;
            2:read_address=address+AW'(WIDTH)+1'b1;
            3:read_address=address+AW'(WIDTH);
            default:read_address=address;
        endcase
    end
    function automatic [PIXEL_W:0] magnitude(input signed [PIXEL_W+1:0] value);
        begin magnitude=(value<0)?-value:value;end
    endfunction
    function automatic [EW-1:0] endpoint(input [1:0] edge_id);
        reg axis;reg [XW-1:0] bx;reg [YW-1:0] by;
        reg [PIXEL_W:0] numerator,other,denominator;
        begin
            axis=0;bx=x;by=y;numerator=0;other=0;
            case(edge_id)
                0:begin numerator=magnitude(deviation[0]);other=magnitude(deviation[1]);end
                1:begin axis=1;bx=x+1'b1;numerator=magnitude(deviation[1]);other=magnitude(deviation[2]);end
                2:begin by=y+1'b1;numerator=magnitude(deviation[3]);other=magnitude(deviation[2]);end
                3:begin axis=1;numerator=magnitude(deviation[0]);other=magnitude(deviation[3]);end
            endcase
            // Selected edges cross the half-level: this sum fits PIXEL_W+1.
            denominator=numerator+other;
            endpoint={axis,bx,by,numerator,denominator};
        end
    endfunction
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && (state==HOLD || state==SUMMARY_HOLD);
    assign m_index=segment_count;
    assign m_is_summary=m_valid && state==SUMMARY_HOLD;
    assign m_first=m_valid && segment_count==0;
    assign m_last=m_is_summary;
    assign m_errors=errors;
    assign m_tag=tag;
    // One single-port clocked-read bank. Full capture precedes every read.
    // Read and write phases never overlap; neither bank nor read-q is reset.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid)image_memory[address]<=s_pixel;
        if(state==LOAD_READ)image_q<=image_memory[read_address];
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;address<=0;x<=0;y<=0;load_slot<=0;
            deviation[0]<=0;deviation[1]<=0;deviation[2]<=0;deviation[3]<=0;
            product_q<=0;first_product<=0;edge0<=0;edge1<=0;edge2<=0;edge3<=0;
            pair_two<=0;pair_second<=0;segment_count<=0;level<=0;tag<=0;errors<=0;
            m_axis0<=0;m_x0<=0;m_y0<=0;m_num0<=0;m_den0<=0;
            m_axis1<=0;m_x1<=0;m_y1<=0;m_num1<=0;m_den1<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(address==0)begin level<=s_level;tag<=s_tag;errors<=incoming_errors;end
                else errors<=errors|incoming_errors;
                if(address==N-1)state<=CHECK;
                else begin address<=address+1'b1;if(x==WIDTH-1)x<=0;else x<=x+1'b1;end
            end
            CHECK:begin
                address<=0;x<=0;y<=0;segment_count<=0;
                if(errors!=0 || WIDTH==1 || HEIGHT==1)state<=SUMMARY_PREP;
                else state<=CELL_START;
            end
            CELL_START:begin load_slot<=0;pair_two<=0;pair_second<=0;state<=LOAD_READ;end
            LOAD_READ:state<=LOAD_LATCH;
            LOAD_LATCH:begin
                deviation[load_slot]<=doubled_sample-doubled_level;
                if(load_slot==3)state<=CLASSIFY;
                else begin load_slot<=load_slot+1'b1;state<=LOAD_READ;end
            end
            CLASSIFY:begin
                case(crossings)
                    4'b0000:state<=ADV;
                    4'b0011:begin edge0<=0;edge1<=1;state<=MAKE;end
                    4'b0101:begin edge0<=0;edge1<=2;state<=MAKE;end
                    4'b1001:begin edge0<=0;edge1<=3;state<=MAKE;end
                    4'b0110:begin edge0<=1;edge1<=2;state<=MAKE;end
                    4'b1010:begin edge0<=1;edge1<=3;state<=MAKE;end
                    4'b1100:begin edge0<=2;edge1<=3;state<=MAKE;end
                    4'b1111:begin pair_two<=1;state<=MUL_A;end
                    default:state<=ADV; // Unreachable for four nonzero corner signs.
                endcase
            end
            MUL_A:begin product_q<=full_product;state<=MUL_SAVE;end
            MUL_SAVE:begin first_product<=product_q;state<=MUL_B;end
            MUL_B:begin product_q<=full_product;state<=DECIDE;end
            DECIDE:begin
                // Q0 uses the same positive level perturbation in every cell.
                if(determinant>0 || (determinant==0 && deviation[0]<0))begin
                    edge0<=0;edge1<=1;edge2<=2;edge3<=3;
                end else begin edge0<=0;edge1<=3;edge2<=1;edge3<=2;end
                state<=MAKE;
            end
            MAKE:begin
                {m_axis0,m_x0,m_y0,m_num0,m_den0}<=endpoint(pair_second?edge2:edge0);
                {m_axis1,m_x1,m_y1,m_num1,m_den1}<=endpoint(pair_second?edge3:edge1);
                state<=HOLD;
            end
            HOLD:if(m_ready)begin
                segment_count<=segment_count+1'b1;
                if(pair_two && !pair_second)begin pair_second<=1;state<=MAKE;end
                else state<=ADV;
            end
            ADV:begin
                if(x==WIDTH-2 && y==HEIGHT-2)state<=SUMMARY_PREP;
                else begin
                    if(x==WIDTH-2)begin x<=0;y<=y+1'b1;address<=address+AW'(2);end
                    else begin x<=x+1'b1;address<=address+1'b1;end
                    state<=CELL_START;
                end
            end
            SUMMARY_PREP:begin
                m_axis0<=0;m_x0<=0;m_y0<=0;m_num0<=0;m_den0<=0;
                m_axis1<=0;m_x1<=0;m_y1<=0;m_num1<=0;m_den1<=0;
                state<=SUMMARY_HOLD;
            end
            SUMMARY_HOLD:if(m_ready)begin address<=0;x<=0;y<=0;state<=CAPTURE;end
            default:state<=CAPTURE;
        endcase
    end
endmodule
