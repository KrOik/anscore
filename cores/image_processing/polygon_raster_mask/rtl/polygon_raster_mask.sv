`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Exact even-odd polygon membership at half-integer raster sample centers.
module polygon_raster_mask #(
    parameter integer COORD_W=12,
    parameter integer MAX_VERTICES=32,
    parameter integer WIDTH=64,
    parameter integer HEIGHT=64,
    parameter integer TAG_W=8,
    localparam integer XW=(WIDTH>1)?$clog2(WIDTH):1,
    localparam integer YW=(HEIGHT>1)?$clog2(HEIGHT):1,
    localparam integer CW=(MAX_VERTICES>0)?$clog2(MAX_VERTICES+1):1
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,
    input wire s_keep,s_last,s_error,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg m_pixel,
    output wire [XW-1:0] m_x,
    output wire [YW-1:0] m_y,
    output wire m_sof,m_eol,m_last,
    output wire [CW-1:0] m_vertices,
    output reg [1:0] m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer DW=COORD_W+2,PW=2*DW,CROSS_W=PW+1;
    localparam [3:0] CAPTURE=0,START_PIXEL=1,A_READ=2,B_READ=3,
        EDGE_SETUP=4,MUL_FIRST=5,MUL_SECOND=6,RESOLVE=7,OUT_HOLD=8;
    reg [3:0] state;
    reg signed [COORD_W-1:0] vertex_x[0:MAX_VERTICES-1],vertex_y[0:MAX_VERTICES-1];
    reg signed [COORD_W-1:0] x_q,y_q,ax,ay;
    reg [CW-1:0] count,edge_index;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg started,parity,boundary,straddles,in_box;
    reg [1:0] errors;
    reg signed [DW-1:0] dx,dy,from_x,from_y;
    reg signed [PW-1:0] first_product;
    wire [CW-1:0] next_vertex=(edge_index+1'b1==count)?{CW{1'b0}}:edge_index+1'b1;
    // Scale both vertices by two; centers become the exact odd integers.
    wire signed [DW-1:0] ax2=$signed({ax[COORD_W-1],ax,1'b0});
    wire signed [DW-1:0] ay2=$signed({ay[COORD_W-1],ay,1'b0});
    wire signed [DW-1:0] bx2=$signed({x_q[COORD_W-1],x_q,1'b0});
    wire signed [DW-1:0] by2=$signed({y_q[COORD_W-1],y_q,1'b0});
    wire signed [DW-1:0] sample_x=$signed({{(DW-XW-1){1'b0}},x,1'b1});
    wire signed [DW-1:0] sample_y=$signed({{(DW-YW-1){1'b0}},y,1'b1});
    wire signed [DW-1:0] mul_a=(state==MUL_FIRST)?dx:dy;
    wire signed [DW-1:0] mul_b=(state==MUL_FIRST)?from_y:from_x;
    wire signed [PW-1:0] product=mul_a*mul_b;
    wire signed [CROSS_W-1:0] cross_value=
        $signed({first_product[PW-1],first_product})-$signed({product[PW-1],product});
    wire ray_cross=straddles && ((dy>0 && cross_value>0)||(dy<0 && cross_value<0));
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_x=x;assign m_y=y;
    assign m_sof=x==0 && y==0;
    assign m_eol=x==WIDTH-1;
    assign m_last=x==WIDTH-1 && y==HEIGHT-1;
    assign m_vertices=count;
`ifndef SYNTHESIS
    initial if(COORD_W<2 || COORD_W>16 || MAX_VERTICES<1 || MAX_VERTICES>64 ||
               WIDTH<1 || HEIGHT<1 || WIDTH>1024 || HEIGHT>1024 || WIDTH*HEIGHT>65536 ||
               WIDTH>(1<<(COORD_W-1)) || HEIGHT>(1<<(COORD_W-1)) || TAG_W<1 || TAG_W>32)
        $fatal(1,"invalid polygon_raster_mask parameters");
`endif
    always @(posedge clk) begin
        if(rst) begin
            state<=CAPTURE;count<=0;edge_index<=0;x<=0;y<=0;started<=0;
            parity<=0;boundary<=0;straddles<=0;in_box<=0;errors<=0;
            x_q<=0;y_q<=0;ax<=0;ay<=0;dx<=0;dy<=0;from_x<=0;from_y<=0;
            first_product<=0;m_pixel<=0;m_error<=0;m_tag<=0;
        end else case(state)
            CAPTURE: if(s_valid) begin
                if(!started) begin m_tag<=s_tag;started<=1;end
                errors<=errors | {s_error,(s_keep && count==MAX_VERTICES)};
                if(s_keep && count<MAX_VERTICES) begin
                    vertex_x[count]<=s_x;vertex_y[count]<=s_y;count<=count+1'b1;
                end
                if(s_last) begin
                    m_error<=errors | {s_error,(s_keep && count==MAX_VERTICES)};
                    x<=0;y<=0;state<=START_PIXEL;
                end
            end
            START_PIXEL: if(m_error!=0 || count<3) begin m_pixel<=0;state<=OUT_HOLD;end
                else begin parity<=0;boundary<=0;edge_index<=0;state<=A_READ;end
            A_READ: begin
                x_q<=vertex_x[edge_index];y_q<=vertex_y[edge_index];state<=B_READ;
            end
            B_READ: begin
                ax<=x_q;ay<=y_q;x_q<=vertex_x[next_vertex];y_q<=vertex_y[next_vertex];
                state<=EDGE_SETUP;
            end
            EDGE_SETUP: begin
                dx<=bx2-ax2;dy<=by2-ay2;from_x<=sample_x-ax2;from_y<=sample_y-ay2;
                straddles<=(ay2>sample_y)!=(by2>sample_y);
                in_box<=((sample_x>=ax2 && sample_x<=bx2)||(sample_x>=bx2 && sample_x<=ax2)) &&
                        ((sample_y>=ay2 && sample_y<=by2)||(sample_y>=by2 && sample_y<=ay2));
                state<=MUL_FIRST;
            end
            MUL_FIRST: begin first_product<=product;state<=MUL_SECOND;end
            MUL_SECOND: begin
                parity<=parity ^ ray_cross;
                boundary<=boundary || (in_box && cross_value==0);
                if(edge_index+1'b1==count) state<=RESOLVE;
                else begin edge_index<=edge_index+1'b1;state<=A_READ;end
            end
            RESOLVE: begin m_pixel<=boundary || parity;state<=OUT_HOLD;end
            OUT_HOLD: if(m_ready) begin
                if(m_last) begin state<=CAPTURE;count<=0;started<=0;errors<=0;end
                else begin
                    if(x==WIDTH-1) begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
                    state<=START_PIXEL;
                end
            end
            default: state<=CAPTURE;
        endcase
    end
endmodule
