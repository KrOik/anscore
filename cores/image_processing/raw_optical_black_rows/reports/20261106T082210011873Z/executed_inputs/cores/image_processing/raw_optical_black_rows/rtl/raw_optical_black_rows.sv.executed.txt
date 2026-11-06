// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Estimates each sensor row from its declared optical-black margins. Payload is
// cropped but uncorrected; row_cfg and row_end explicitly own the correction epoch.
module raw_optical_black_rows #(
    parameter integer WIDTH=128,HEIGHT=64,BITS=10,OB_LEFT=8,OB_RIGHT=8,TAG_W=8
)(
    input wire clk,rst,input wire c_valid,output wire c_ready,
    input wire [BITS-1:0] c_low,c_high,c_target,input wire [5:0] c_min_count,
    input wire [1:0] c_pattern,input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,input wire [BITS-1:0] s_data,input wire s_sof,s_eol,s_last,
    output wire row_valid,input wire row_ready,output wire [BITS-1:0] row_black0,row_black1,row_target,
    output wire [15:0] row_y,output wire [1:0] row_pattern,output wire [TAG_W-1:0] row_tag,
    output wire row_end_valid,input wire row_end_ready,
    output wire m_valid,input wire m_ready,output wire [BITS-1:0] m_data,m_black,
    output wire m_sof,m_eol,m_last,output wire [15:0] m_x,m_y,
    output wire [1:0] m_pattern,output wire [TAG_W-1:0] m_tag,
    output wire d_valid,input wire d_ready,output reg [3:0] d_error,
    output reg [9:0] d_rows,output reg [16:0] d_pixels,output wire [TAG_W-1:0] d_tag,
    output wire busy
);
    localparam integer SW=OB_LEFT+WIDTH+OB_RIGHT;
    localparam integer SXW=$clog2(SW),YW=HEIGHT>1?$clog2(HEIGHT):1;
    localparam integer AW=WIDTH>1?$clog2(WIDTH):1,IW=$clog2(WIDTH+1);
    localparam [3:0] IDLE=0,CAPTURE=1,CHECK=2,DIV_INIT=3,DIV_STEP=4,DIV_STORE=5,ROW_CFG=6,REPLAY=7,FENCE=8,DONE=9;
    reg [3:0] state;
    reg [SXW-1:0] sx;reg [YW-1:0] y;
    reg [IW-1:0] issued;reg [AW-1:0] ox;
    reg [BITS-1:0] low,high,target,mean0,mean1,row_q;
    reg [5:0] minimum,count0,count1,denom;
    reg [16:0] sum0,sum1,numerator,quotient;
    reg [5:0] remainder;reg [4:0] iteration;reg plane,out_valid;
    reg [1:0] pattern;reg [TAG_W-1:0] tag;
    (* ram_style="block" *) reg [BITS-1:0] row_mem[0:WIDTH-1];
    wire active_x=sx>=OB_LEFT && sx<OB_LEFT+WIDTH;
    wire take=s_valid&&s_ready;
    wire qualified=!active_x && s_data>=low && s_data<=high;
    wire bad_marker=s_sof!=(sx==0&&y==0) || s_eol!=(sx==SW-1) || s_last!=(sx==SW-1&&y==HEIGHT-1);
    wire step=!out_valid||m_ready;
    wire [6:0] trial={remainder,numerator[16]};
    wire subtract=trial>={1'b0,denom};
    assign c_ready=!rst&&state==IDLE;
    assign s_ready=!rst&&state==CAPTURE;
    assign row_valid=!rst&&state==ROW_CFG;
    assign row_black0=(OB_LEFT%2)==0?mean0:mean1;
    assign row_black1=(OB_LEFT%2)==0?mean1:mean0;
    assign row_target=target;assign row_y=16'(y);assign row_pattern=pattern;
    assign row_tag=tag;
    assign row_end_valid=!rst&&state==FENCE;
    assign m_valid=!rst&&state==REPLAY&&out_valid;
    assign m_data=row_q;assign m_black=ox[0]?row_black1:row_black0;
    assign m_x=16'(ox);assign m_y=16'(y);assign m_pattern=pattern;assign m_tag=tag;
    assign m_sof=y==0&&ox==0;assign m_eol=ox==WIDTH-1;assign m_last=m_eol&&y==HEIGHT-1;
    assign d_valid=!rst&&state==DONE;assign d_tag=tag;
    assign busy=!rst&&state!=IDLE;
    // Write and read phases cannot overlap. RAM payload is never reset.
    always @(posedge clk)if(!rst)begin
        if(take&&active_x)row_mem[AW'(sx-OB_LEFT)]<=s_data;
        if(state==REPLAY&&step&&issued<WIDTH)row_q<=row_mem[AW'(issued)];
    end
    initial if(WIDTH<1||WIDTH>512||HEIGHT<1||HEIGHT>512||WIDTH*HEIGHT>65536||
        (BITS!=8&&BITS!=10&&BITS!=12)||OB_LEFT<2||OB_LEFT>32||OB_RIGHT<0||OB_RIGHT>32||TAG_W<1||TAG_W>32)
        $fatal(1,"raw_optical_black_rows invalid specialization");
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;sx<=0;y<=0;issued<=0;ox<=0;low<=0;high<=0;target<=0;minimum<=0;
            mean0<=0;mean1<=0;count0<=0;count1<=0;sum0<=0;sum1<=0;denom<=0;numerator<=0;
            quotient<=0;remainder<=0;iteration<=0;plane<=0;out_valid<=0;pattern<=0;tag<=0;
            d_error<=0;d_rows<=0;d_pixels<=0;
        end else case(state)
            IDLE:if(c_valid)begin
                low<=c_low;high<=c_high;target<=c_target;minimum<=c_min_count;
                pattern<=c_pattern^{1'b0,1'(OB_LEFT%2)};tag<=c_tag;
                sx<=0;y<=0;sum0<=0;sum1<=0;count0<=0;count1<=0;out_valid<=0;d_rows<=0;d_pixels<=0;d_error<=0;
                if(c_low>c_high||c_min_count==0||c_min_count>32)begin d_error<=1;state<=DONE;end
                else state<=CAPTURE;
            end
            CAPTURE:if(take)begin
                if(bad_marker)begin d_error<=2;state<=DONE;end
                else begin
                    if(qualified)begin
                        if(sx[0])begin sum1<=sum1+17'(s_data);count1<=count1+1'b1;end
                        else begin sum0<=sum0+17'(s_data);count0<=count0+1'b1;end
                    end
                    if(sx==SW-1)state<=CHECK;else sx<=sx+1'b1;
                end
            end
            CHECK:begin
                if(count0<minimum)begin d_error<=3;state<=DONE;end
                else if(count1<minimum)begin d_error<=4;state<=DONE;end
                else begin plane<=0;state<=DIV_INIT;end
            end
            DIV_INIT:begin
                numerator<=(plane?sum1:sum0)+17'((plane?count1:count0)>>1);
                denom<=plane?count1:count0;quotient<=0;remainder<=0;iteration<=0;state<=DIV_STEP;
            end
            DIV_STEP:begin
                numerator<={numerator[15:0],1'b0};quotient<={quotient[15:0],subtract};
                remainder<=6'(subtract?trial-{1'b0,denom}:trial);
                if(iteration==16)state<=DIV_STORE;else iteration<=iteration+1'b1;
            end
            DIV_STORE:begin
                if(!plane)begin mean0<=quotient[BITS-1:0];plane<=1;state<=DIV_INIT;end
                else begin mean1<=quotient[BITS-1:0];state<=ROW_CFG;end
            end
            ROW_CFG:if(row_ready)begin issued<=0;out_valid<=0;state<=REPLAY;end
            REPLAY:begin
                if(step)begin
                    out_valid<=issued<WIDTH;
                    if(issued<WIDTH)begin ox<=AW'(issued);issued<=issued+1'b1;end
                end
                if(m_valid&&m_ready)begin
                    d_pixels<=d_pixels+1'b1;
                    if(m_eol)begin out_valid<=0;state<=FENCE;end
                end
            end
            FENCE:if(row_end_ready)begin
                d_rows<=d_rows+1'b1;
                if(y==HEIGHT-1)state<=DONE;
                else begin y<=y+1'b1;sx<=0;sum0<=0;sum1<=0;count0<=0;count1<=0;state<=CAPTURE;end
            end
            DONE:if(d_ready)state<=IDLE;
            default:begin d_error<=15;state<=DONE;out_valid<=0;end
        endcase
    end
endmodule
