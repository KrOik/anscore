// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// One coverage/destination rendezvous -> serial exact paint scaling -> real PD.
module rgba_aa_rect_blend #(
    parameter integer WIDTH=64,HEIGHT=64,TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire signed [23:0] c_x0,c_y0,c_x1,c_y1,
    input wire [31:0] c_paint,input wire [3:0] c_mode,
    input wire [TAG_W-1:0] c_tag,
    input wire d_valid,output wire d_ready,input wire [31:0] d_rgba,
    output wire m_valid,input wire m_ready,output wire [31:0] m_rgba,
    output wire [1:0] m_error,output wire [3:0] m_mode,
    output wire [15:0] m_x,m_y,output wire [TAG_W-1:0] m_tag,
    output wire [16:0] m_area,output wire m_last,
    output wire r_valid,input wire r_ready,output wire [1:0] r_status,
    output wire [16:0] r_count,output wire [32:0] r_area_sum,
    output wire [TAG_W-1:0] r_tag,output reg [16:0] r_error_count,
    output wire busy
);
    localparam [1:0] F_IDLE=0,F_SCALE=1,F_PUSH=2,F_WAIT=3;
    reg [1:0] fstate,channel;
    reg owner,bad_paint;
    reg [31:0] paintq,scaledq,dstq;
    reg [3:0] modeq;
    reg [16:0] areaq;
    reg [15:0] xq,yq;
    reg lastq;
    reg [TAG_W-1:0] tagq;
    wire cc_ready,cm_valid,cm_ready,cm_last,cr_valid,cr_ready;
    wire [15:0] cm_x,cm_y;
    wire [16:0] cm_area;
    wire [TAG_W-1:0] cm_tag;
    wire pd_ready,pd_valid,pd_busy;
    wire idle_fragment=fstate==F_IDLE;
    assign c_ready=!rst && !owner && cc_ready;
    assign busy=!rst && owner;
    assign cm_ready=!rst && idle_fragment && d_valid;
    assign d_ready=!rst && idle_fragment && cm_valid;
    assign r_valid=!rst && owner && idle_fragment && cr_valid;
    assign cr_ready=!rst && owner && idle_fragment && r_ready;
    assign m_valid=!rst && fstate==F_WAIT && pd_valid;
    assign m_area=areaq;assign m_last=lastq;
    subpixel_rect_coverage #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) coverage(
        .clk(clk),.rst(rst),.c_valid(c_valid && !owner),.c_ready(cc_ready),
        .c_x0(c_x0),.c_y0(c_y0),.c_x1(c_x1),.c_y1(c_y1),.c_tag(c_tag),
        .m_valid(cm_valid),.m_ready(cm_ready),.m_x(cm_x),.m_y(cm_y),.m_area(cm_area),
        .m_last(cm_last),.m_tag(cm_tag),.r_valid(cr_valid),.r_ready(cr_ready),
        .r_status(r_status),.r_count(r_count),.r_area_sum(r_area_sum),.r_tag(r_tag),.busy()
    );
    // One physical multiply expression reused over A, B, G, R.
    wire [7:0] paint_channel=paintq[channel*8+:8];
    wire [24:0] scale_product=areaq*paint_channel;
    wire round_up=scale_product[15:0]>16'h8000 ||
        (scale_product[15:0]==16'h8000 && scale_product[16]);
    wire [8:0] scaled_channel={1'b0,scale_product[23:16]}+{8'd0,round_up};
    rgba_porter_duff #(.TAG_W(TAG_W)) blend(
        .clk(clk),.rst(rst),.s_valid(!rst && fstate==F_PUSH),.s_ready(pd_ready),
        .s_src(bad_paint ? 32'h01000000:scaledq),.s_dst(dstq),.s_mode(modeq),
        .s_x(xq),.s_y(yq),.s_tag(tagq),.m_valid(pd_valid),
        .m_ready(!rst && fstate==F_WAIT && m_ready),.m_rgba(m_rgba),.m_error(m_error),
        .m_mode(m_mode),.m_x(m_x),.m_y(m_y),.m_tag(m_tag),.pipeline_busy(pd_busy)
    );
    always @(posedge clk) begin
        if(rst) begin
            fstate<=F_IDLE;channel<=0;owner<=0;bad_paint<=0;
            paintq<=0;scaledq<=0;dstq<=0;modeq<=0;areaq<=0;
            xq<=0;yq<=0;lastq<=0;tagq<=0;r_error_count<=0;
        end else begin
            if(c_valid && c_ready) begin
                owner<=1;paintq<=c_paint;modeq<=c_mode;r_error_count<=0;
                bad_paint<=c_paint[31:24]>c_paint[7:0] ||
                    c_paint[23:16]>c_paint[7:0] || c_paint[15:8]>c_paint[7:0];
            end
            if(r_valid && r_ready) owner<=0;
            case(fstate)
                F_IDLE: if(cm_valid && d_valid) begin
                    dstq<=d_rgba;areaq<=cm_area;xq<=cm_x;yq<=cm_y;
                    lastq<=cm_last;tagq<=cm_tag;channel<=0;scaledq<=0;fstate<=F_SCALE;
                end
                F_SCALE: begin
                    scaledq[channel*8+:8]<=scaled_channel[7:0];
                    if(channel==3) fstate<=F_PUSH;
                    else channel<=channel+2'd1;
                end
                F_PUSH: if(pd_ready) fstate<=F_WAIT;
                F_WAIT: if(pd_valid && m_ready) begin
                    if(m_error!=0) r_error_count<=r_error_count+17'd1;
                    fstate<=F_IDLE;
                end
            endcase
        end
    end
endmodule
