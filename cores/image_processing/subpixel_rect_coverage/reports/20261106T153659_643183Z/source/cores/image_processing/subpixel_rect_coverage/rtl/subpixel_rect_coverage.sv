// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Exact area of a half-open Q8 rectangle intersected with viewport pixel cells.
module subpixel_rect_coverage #(
    parameter integer WIDTH=64, HEIGHT=64, TAG_W=8
)(
    input wire clk, rst,
    input wire c_valid, output wire c_ready,
    input wire signed [23:0] c_x0,c_y0,c_x1,c_y1,
    input wire [TAG_W-1:0] c_tag,
    output wire m_valid, input wire m_ready,
    output wire [15:0] m_x,m_y,
    output reg [16:0] m_area,
    output wire m_last, output wire [TAG_W-1:0] m_tag,
    output wire r_valid, input wire r_ready,
    output reg [1:0] r_status,
    output reg [16:0] r_count,
    output reg [32:0] r_area_sum,
    output wire [TAG_W-1:0] r_tag,
    output wire busy
);
    localparam [1:0] IDLE=0,CALC=1,OUT=2,DONE=3;
    localparam signed [23:0] XLIMIT=WIDTH*256, YLIMIT=HEIGHT*256;
    reg [1:0] state;
    reg [16:0] x0q,y0q,x1q,y1q;
    reg [7:0] x,y,start_x,end_x,end_y;
    reg [TAG_W-1:0] tagq;
    wire [16:0] cx0=c_x0<0 ? 17'd0 : c_x0>XLIMIT ? XLIMIT[16:0] : c_x0[16:0];
    wire [16:0] cy0=c_y0<0 ? 17'd0 : c_y0>YLIMIT ? YLIMIT[16:0] : c_y0[16:0];
    wire [16:0] cx1=c_x1<0 ? 17'd0 : c_x1>XLIMIT ? XLIMIT[16:0] : c_x1[16:0];
    wire [16:0] cy1=c_y1<0 ? 17'd0 : c_y1>YLIMIT ? YLIMIT[16:0] : c_y1[16:0];
    wire [16:0] cx1m1=cx1-17'd1, cy1m1=cy1-17'd1;
    wire [16:0] px0={1'b0,x,8'b0},py0={1'b0,y,8'b0};
    wire [16:0] px1=px0+17'd256,py1=py0+17'd256;
    wire [16:0] lx=x0q>px0 ? x0q:px0, hx=x1q<px1 ? x1q:px1;
    wire [16:0] ly=y0q>py0 ? y0q:py0, hy=y1q<py1 ? y1q:py1;
    // On CALC, the sparse bounding box guarantees each extent is in 1..256.
    wire [8:0] dx=hx-lx,dy=hy-ly;
    wire [17:0] product=dx*dy;
    assign c_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==OUT;
    assign m_x={8'd0,x}; assign m_y={8'd0,y};
    assign m_last=x==end_x && y==end_y;
    assign m_tag=tagq; assign r_tag=tagq;
    assign r_valid=!rst && state==DONE;
    assign busy=!rst && state!=IDLE;
    initial begin
        if(WIDTH<1 || WIDTH>256 || HEIGHT<1 || HEIGHT>256 || TAG_W<1 || TAG_W>32)
            $fatal(1,"subpixel_rect_coverage parameters outside contract");
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;x0q<=0;y0q<=0;x1q<=0;y1q<=0;
            x<=0;y<=0;start_x<=0;end_x<=0;end_y<=0;tagq<=0;
            m_area<=0;r_status<=0;r_count<=0;r_area_sum<=0;
        end else case(state)
            IDLE: if(c_valid) begin
                tagq<=c_tag;r_count<=0;r_area_sum<=0;
                if(c_x1<c_x0 || c_y1<c_y0) begin
                    r_status<=2'd1;state<=DONE;
                end else if(cx1<=cx0 || cy1<=cy0) begin
                    r_status<=2'd2;state<=DONE;
                end else begin
                    r_status<=0;x0q<=cx0;y0q<=cy0;x1q<=cx1;y1q<=cy1;
                    x<=cx0[15:8];y<=cy0[15:8];start_x<=cx0[15:8];
                    end_x<=cx1m1[15:8];end_y<=cy1m1[15:8];state<=CALC;
                end
            end
            CALC: begin m_area<=product[16:0];state<=OUT;end
            OUT: if(m_ready) begin
                r_count<=r_count+17'd1;
                r_area_sum<=r_area_sum+{16'd0,m_area};
                if(m_last) state<=DONE;
                else begin
                    if(x==end_x) begin x<=start_x;y<=y+8'd1;end
                    else x<=x+8'd1;
                    state<=CALC;
                end
            end
            DONE: if(r_ready) state<=IDLE;
        endcase
    end
endmodule
