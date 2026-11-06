// SPDX-License-Identifier: Apache-2.0
// Exact Gouraud triangle fragments, top-left coverage and one shared multiplier.
`default_nettype none
module triangle_rgb_raster #(
    parameter integer WIDTH=64,HEIGHT=64,TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire signed [9:0] c_x0,c_y0,c_x1,c_y1,c_x2,c_y2,
    input wire [23:0] c_rgb0,c_rgb1,c_rgb2,input wire [TAG_W-1:0] c_tag,
    output wire m_valid,input wire m_ready,
    output wire [7:0] m_x,m_y,output wire [23:0] m_rgb,
    output wire m_first,output wire [TAG_W-1:0] m_tag,
    output wire d_valid,input wire d_ready,output wire [1:0] d_status,
    output wire [16:0] d_count,output wire [TAG_W-1:0] d_tag
);
    generate if(WIDTH<1||WIDTH>256||HEIGHT<1||HEIGHT>256||TAG_W<1||TAG_W>32) begin: bad_parameters
        triangle_rgb_raster_invalid_parameters invalid();
    end endgenerate
    localparam [4:0] IDLE=0,AREA_A=1,AREA_B=2,ORIENT=3,BOUNDS=4,
        EDGE_A=5,EDGE_B=6,EDGE_STORE=7,SCAN=8,COLOR_MUL=9,COLOR_ACC=10,
        DIVIDE=11,SAVE=12,OUTPUT_PIXEL=13,ADVANCE=14,DONE=15;
    reg [4:0] state;
    reg signed [9:0] vx[0:2],vy[0:2];
    reg [23:0] rgb[0:2];
    reg [TAG_W-1:0] tag;
    reg [1:0] status,edge_id,term,channel;
    reg [7:0] x,y,x_min,x_max,y_min,y_max;
    reg signed [23:0] edge_value[0:2],row_edge[0:2],step_x[0:2],step_y[0:2];
    reg [2:0] inclusive;
    reg [23:0] area,color;
    reg [16:0] count;
    reg signed [23:0] mul_a,first_product;
    reg signed [11:0] mul_b;
    wire signed [35:0] product=mul_a*mul_b;
    wire signed [24:0] determinant=$signed(first_product)-$signed(product[23:0]);
    reg [31:0] accumulator,remainder,trial;
    reg [7:0] quotient;
    reg [2:0] bit_id;
    reg signed [9:0] ax,ay,bx,by;
    integer j;
    function automatic signed [23:0] wide(input signed [9:0] value);
        begin wide={{14{value[9]}},value};end
    endfunction
    function automatic signed [11:0] coord12(input signed [9:0] value);
        begin coord12={{2{value[9]}},value};end
    endfunction
    function automatic signed [11:0] pixel_coord(input [7:0] value);
        begin pixel_coord=$signed({4'b0,value});end
    endfunction
    function automatic signed [9:0] min3(input signed [9:0] a,b,c);
        reg signed [9:0] t;
        begin t=(a<b)?a:b;min3=(t<c)?t:c;end
    endfunction
    function automatic signed [9:0] max3(input signed [9:0] a,b,c);
        reg signed [9:0] t;
        begin t=(a>b)?a:b;max3=(t>c)?t:c;end
    endfunction
    wire signed [10:0] low_x=min3(vx[0],vx[1],vx[2]);
    wire signed [10:0] low_y=min3(vy[0],vy[1],vy[2]);
    wire signed [10:0] high_x=$signed(max3(vx[0],vx[1],vx[2]))-11'sd1;
    wire signed [10:0] high_y=$signed(max3(vy[0],vy[1],vy[2]))-11'sd1;
    always @* begin
        case(edge_id)
            0: begin ax=vx[1];ay=vy[1];bx=vx[2];by=vy[2];end
            1: begin ax=vx[2];ay=vy[2];bx=vx[0];by=vy[0];end
            default: begin ax=vx[0];ay=vy[0];bx=vx[1];by=vy[1];end
        endcase
    end
    wire inside0=(edge_value[0]>0)||(edge_value[0]==0&&inclusive[0]);
    wire inside1=(edge_value[1]>0)||(edge_value[1]==0&&inclusive[1]);
    wire inside2=(edge_value[2]>0)||(edge_value[2]==0&&inclusive[2]);
    wire [7:0] component=rgb[term][channel*8+:8];
    assign c_ready=!rst&&state==IDLE;
    assign m_valid=!rst&&state==OUTPUT_PIXEL;
    assign m_x=x;assign m_y=y;assign m_rgb=color;
    assign m_first=count==0;assign m_tag=tag;
    assign d_valid=!rst&&state==DONE;
    assign d_status=status;assign d_count=count;assign d_tag=tag;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;count<=0;tag<=0;status<=0;x<=0;y<=0;color<=0;
            edge_id<=0;term<=0;channel<=0;mul_a<=0;mul_b<=0;
            first_product<=0;area<=0;accumulator<=0;remainder<=0;trial<=0;quotient<=0;bit_id<=0;
            x_min<=0;x_max<=0;y_min<=0;y_max<=0;inclusive<=0;
        end else begin
            case(state)
                IDLE: if(c_valid) begin
                    vx[0]<=c_x0;vy[0]<=c_y0;vx[1]<=c_x1;vy[1]<=c_y1;vx[2]<=c_x2;vy[2]<=c_y2;
                    rgb[0]<=c_rgb0;rgb[1]<=c_rgb1;rgb[2]<=c_rgb2;tag<=c_tag;
                    count<=0;status<=0;state<=AREA_A;
                end
                AREA_A: begin
                    mul_a<=wide(vx[1])-wide(vx[0]);mul_b<=coord12(vy[2])-coord12(vy[0]);state<=AREA_B;
                end
                AREA_B: begin
                    first_product<=product[23:0];mul_a<=wide(vy[1])-wide(vy[0]);mul_b<=coord12(vx[2])-coord12(vx[0]);state<=ORIENT;
                end
                ORIENT: begin
                    if(determinant==0) begin status<=1;state<=DONE;end
                    else begin
                        if(determinant<0) begin
                            vx[1]<=vx[2];vy[1]<=vy[2];rgb[1]<=rgb[2];
                            vx[2]<=vx[1];vy[2]<=vy[1];rgb[2]<=rgb[1];
                            area<=(-determinant)<<<1;
                        end else area<=determinant<<<1;
                        state<=BOUNDS;
                    end
                end
                BOUNDS: begin
                    if(high_x<0||high_y<0||low_x>=WIDTH||low_y>=HEIGHT) begin status<=2;state<=DONE;end
                    else begin
                        x_min<=(low_x<0)?0:low_x[7:0];x<=(low_x<0)?0:low_x[7:0];
                        y_min<=(low_y<0)?0:low_y[7:0];y<=(low_y<0)?0:low_y[7:0];
                        x_max<=(high_x>=WIDTH)?WIDTH-1:high_x[7:0];
                        y_max<=(high_y>=HEIGHT)?HEIGHT-1:high_y[7:0];
                        edge_id<=0;state<=EDGE_A;
                    end
                end
                EDGE_A: begin
                    mul_a<=wide(bx)-wide(ax);
                    mul_b<=(pixel_coord(y_min)<<<1)+12'sd1-(coord12(ay)<<<1);
                    state<=EDGE_B;
                end
                EDGE_B: begin
                    first_product<=product[23:0];mul_a<=wide(by)-wide(ay);
                    mul_b<=(pixel_coord(x_min)<<<1)+12'sd1-(coord12(ax)<<<1);
                    step_x[edge_id]<=-(wide(by)-wide(ay))<<<1;
                    step_y[edge_id]<=(wide(bx)-wide(ax))<<<1;
                    inclusive[edge_id]<=(by<ay)||((by==ay)&&(bx>ax));
                    state<=EDGE_STORE;
                end
                EDGE_STORE: begin
                    edge_value[edge_id]<=first_product-$signed(product[23:0]);
                    row_edge[edge_id]<=first_product-$signed(product[23:0]);
                    if(edge_id==2) state<=SCAN;
                    else begin edge_id<=edge_id+1'b1;state<=EDGE_A;end
                end
                SCAN: begin
                    if(inside0&&inside1&&inside2) begin channel<=0;term<=0;accumulator<=0;state<=COLOR_MUL;end
                    else state<=ADVANCE;
                end
                COLOR_MUL: begin mul_a<=edge_value[term];mul_b<=$signed({4'b0,component});state<=COLOR_ACC;end
                COLOR_ACC: begin
                    if(term==2) begin
                        remainder<=accumulator+product[31:0]+(area>>1);
                        trial<={8'b0,area}<<7;quotient<=0;bit_id<=7;state<=DIVIDE;
                    end else begin accumulator<=accumulator+product[31:0];term<=term+1'b1;state<=COLOR_MUL;end
                end
                DIVIDE: begin
                    if(remainder>=trial) begin remainder<=remainder-trial;quotient[bit_id]<=1;end
                    if(bit_id==0) state<=SAVE;
                    else begin bit_id<=bit_id-1'b1;trial<=trial>>1;end
                end
                SAVE: begin
                    color[channel*8+:8]<=quotient;
                    if(channel==2) state<=OUTPUT_PIXEL;
                    else begin channel<=channel+1'b1;term<=0;accumulator<=0;state<=COLOR_MUL;end
                end
                OUTPUT_PIXEL: if(m_ready) begin count<=count+1'b1;state<=ADVANCE;end
                ADVANCE: begin
                    if(x==x_max) begin
                        if(y==y_max) state<=DONE;
                        else begin
                            x<=x_min;y<=y+1'b1;
                            for(j=0;j<3;j=j+1) begin row_edge[j]<=row_edge[j]+step_y[j];edge_value[j]<=row_edge[j]+step_y[j];end
                            state<=SCAN;
                        end
                    end else begin
                        x<=x+1'b1;
                        for(j=0;j<3;j=j+1) edge_value[j]<=edge_value[j]+step_x[j];
                        state<=SCAN;
                    end
                end
                DONE: if(d_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
