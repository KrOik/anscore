`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// One-pass digital topology summary with one previous-row bit memory.
module streaming_binary_topology #(
    parameter integer WIDTH=64,
    parameter integer HEIGHT=64,
    parameter integer TAG_W=8,
    localparam integer XW=(WIDTH>1)?$clog2(WIDTH):1,
    localparam integer YW=(HEIGHT>1)?$clog2(HEIGHT):1,
    localparam integer AW=(WIDTH*HEIGHT>1)?$clog2(WIDTH*HEIGHT+1):1,
    localparam integer PW=$clog2(4*WIDTH*HEIGHT+1),
    localparam integer EW=AW+1,
    localparam integer NW=$clog2(2*(WIDTH+1)*(HEIGHT+1)+1)+1
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire s_pixel,s_sof,s_eol,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [EW-1:0] m_euler4,m_euler8,
    output reg [AW-1:0] m_area,
    output reg [PW-1:0] m_perimeter,
    output wire m_empty,
    output reg m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam [2:0] INPUT_PIXEL=0,PIXEL=1,RIGHT_EDGE=2,
        BOTTOM_READ=3,BOTTOM_PIXEL=4,CORNER=5,EMIT=6;
    reg [2:0] state;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg line[0:WIDTH-1];
    reg line_q,pixel,upper_left,left;
    reg signed [NW-1:0] numerator4,numerator8;
    reg [3:0] pattern;
    reg signed [2:0] delta4,delta8;
    wire upper=(state==PIXEL && y==0)?1'b0:line_q;
    wire [2:0] perimeter_increment=pixel ?
        (3'd4-(left?3'd2:3'd0)-(upper?3'd2:3'd0)):3'd0;
    always @* begin
        pattern=4'b0;
        case(state)
            PIXEL: pattern={upper_left,upper,left,pixel};
            RIGHT_EDGE: pattern={upper_left,1'b0,left,1'b0};
            BOTTOM_PIXEL: pattern={upper_left,line_q,1'b0,1'b0};
            CORNER: pattern={upper_left,3'b0};
            default: pattern=4'b0;
        endcase
        delta4=0;delta8=0;
        case(pattern)
            4'b0001,4'b0010,4'b0100,4'b1000: begin delta4=1;delta8=1;end
            4'b1110,4'b1101,4'b1011,4'b0111: begin delta4=-1;delta8=-1;end
            4'b1001,4'b0110: begin delta4=2;delta8=-2;end
            default: begin delta4=0;delta8=0;end
        endcase
    end
    assign s_ready=!rst && state==INPUT_PIXEL;
    assign m_valid=!rst && state==EMIT;
    assign m_empty=m_area==0;
`ifndef SYNTHESIS
    initial if(WIDTH<1 || WIDTH>1024 || HEIGHT<1 || HEIGHT>1024 ||
               TAG_W<1 || TAG_W>32)
        $fatal(1,"invalid streaming_binary_topology parameters");
`endif
    always @(posedge clk) begin
        if(rst) begin
            state<=INPUT_PIXEL;x<=0;y<=0;upper_left<=0;left<=0;
            numerator4<=0;numerator8<=0;
            m_euler4<=0;m_euler8<=0;m_area<=0;m_perimeter<=0;
            m_error<=0;m_tag<=0;
        end else case(state)
            INPUT_PIXEL: if(s_valid) begin
                line_q<=line[x];pixel<=s_pixel;
                if(x==0 && y==0) m_tag<=s_tag;
                if(s_sof!=(x==0 && y==0) || s_eol!=(x==WIDTH-1)) m_error<=1;
                state<=PIXEL;
            end
            PIXEL: begin
                numerator4<=numerator4+$signed(delta4);
                numerator8<=numerator8+$signed(delta8);
                m_area<=m_area+pixel;
                m_perimeter<=m_perimeter+perimeter_increment;
                line[x]<=pixel;upper_left<=upper;left<=pixel;
                if(x==WIDTH-1) state<=RIGHT_EDGE;
                else begin x<=x+1'b1;state<=INPUT_PIXEL;end
            end
            RIGHT_EDGE: begin
                numerator4<=numerator4+$signed(delta4);
                numerator8<=numerator8+$signed(delta8);
                x<=0;upper_left<=0;left<=0;
                if(y==HEIGHT-1) state<=BOTTOM_READ;
                else begin y<=y+1'b1;state<=INPUT_PIXEL;end
            end
            BOTTOM_READ: begin line_q<=line[x];state<=BOTTOM_PIXEL;end
            BOTTOM_PIXEL: begin
                numerator4<=numerator4+$signed(delta4);
                numerator8<=numerator8+$signed(delta8);
                upper_left<=line_q;
                if(x==WIDTH-1) state<=CORNER;
                else begin x<=x+1'b1;state<=BOTTOM_READ;end
            end
            CORNER: begin
                // Every padded 2x2 vertex is now included; both totals /4 are exact.
                m_euler4<=($signed(numerator4)+$signed(delta4))>>>2;
                m_euler8<=($signed(numerator8)+$signed(delta8))>>>2;
                state<=EMIT;
            end
            EMIT: if(m_ready) begin
                state<=INPUT_PIXEL;x<=0;y<=0;upper_left<=0;left<=0;
                numerator4<=0;numerator8<=0;m_euler4<=0;m_euler8<=0;
                m_area<=0;m_perimeter<=0;m_error<=0;
            end
        endcase
    end
endmodule
