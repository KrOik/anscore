// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module binary_hu_moments #(
    parameter integer WIDTH=8, HEIGHT=8, TAG_W=8,
    localparam integer WX=(WIDTH<1)?1:WIDTH, HY=(HEIGHT<1)?1:HEIGHT,
    localparam integer N=WX*HY,
    localparam integer A=($clog2(N)<1)?1:$clog2(N),
    localparam integer L=($clog2((WX>HY)?WX:HY)<1)?1:$clog2((WX>HY)?WX:HY),
    localparam integer RAW_W=A+3*L+1,
    localparam integer WORK_W=(12*(A+L)+9>18*A+2)?12*(A+L)+9:18*A+2,
    localparam integer COUNT_W=$clog2(N+1),
    localparam integer XW=($clog2(WX)<1)?1:$clog2(WX),
    localparam integer YW=($clog2(HY)<1)?1:$clog2(HY),
    localparam integer SW=($clog2(WORK_W)<1)?1:$clog2(WORK_W)
)(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire s_pixel,s_sof,s_eol,s_bad,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg signed [WORK_W-1:0] m_numerator,
    output reg [WORK_W-1:0] m_denominator,
    output wire [2:0] m_index,
    output wire m_keep,m_last,
    output wire [3:0] m_errors,
    output reg [COUNT_W-1:0] m_area,
    output wire [TAG_W-1:0] m_tag
);
    localparam [3:0] CAPTURE=0,RAW_STORE=1,READ_A=2,READ_B=3,EXEC=4,
        ABS_A=5,ABS_B=6,MUL=7,SIGN_RESULT=8,WRITE=9,
        OUT_NUM=10,OUT_DEN=11,OUT_LOAD=12,OUT_HOLD=13,ERROR_HOLD=14;
    reg [3:0] state;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg [COUNT_W-1:0] capture_count;
    reg [3:0] errors;
    reg [TAG_W-1:0] tag_q;
    // Raw moments are scalar accumulators: ten simultaneous independent writes.
    reg [RAW_W-1:0] raw[0:9];
    reg [2*L-1:0] xx,xy,yy;
    reg [3*L-1:0] xxx,xxy,xyy,yyy;
    wire [RAW_W-1:0] mono[0:9];
    assign mono[0]={{(RAW_W-1){1'b0}},1'b1};
    assign mono[1]={{(RAW_W-XW){1'b0}},x};
    assign mono[2]={{(RAW_W-YW){1'b0}},y};
    assign mono[3]={{(RAW_W-2*L){1'b0}},xx};
    assign mono[4]={{(RAW_W-2*L){1'b0}},xy};
    assign mono[5]={{(RAW_W-2*L){1'b0}},yy};
    assign mono[6]={{(RAW_W-3*L){1'b0}},xxx};
    assign mono[7]={{(RAW_W-3*L){1'b0}},xxy};
    assign mono[8]={{(RAW_W-3*L){1'b0}},xyy};
    assign mono[9]={{(RAW_W-3*L){1'b0}},yyy};
    wire [RAW_W-1:0] area_next=(capture_count==0)?(s_pixel?mono[0]:0):raw[0]+s_pixel;
    wire [3:0] capture_errors=errors|{s_bad,(s_eol!=(x==WX-1)),
                                                   (s_sof!=(capture_count==0)),1'b0};
    // Only one scratch read OR write per edge. No payload/read-q reset.
    reg signed [WORK_W-1:0] scratch[0:31],scratch_q;
    reg [3:0] raw_index;
    reg [6:0] pc;
    reg [2:0] out_index;
    reg [1:0] op,shift_a,shift_b;
    reg [4:0] addr_a,addr_b,addr_d,out_num_addr,out_den_addr;
    `include "instructions.vh"
    reg signed [WORK_W-1:0] operand_a,operand_b,result;
    reg [WORK_W-1:0] mul_shift,mul_factor,mul_acc;
    reg [SW-1:0] mul_step;
    reg mul_negative;
    wire signed [WORK_W-1:0] shifted_b=$signed(scratch_q)<<<shift_b;
    reg [WORK_W-1:0] alu_a,alu_b;
    reg alu_sub;
    always @* begin
        alu_a=0;alu_b=0;alu_sub=0;
        case(state)
            EXEC:begin alu_a=operand_a;alu_b=shifted_b;alu_sub=(op==1);end
            ABS_A:begin alu_b=operand_a;alu_sub=operand_a[WORK_W-1];end
            ABS_B:begin alu_b=operand_b;alu_sub=operand_b[WORK_W-1];end
            MUL:begin alu_a=mul_acc;alu_b=mul_factor[0]?mul_shift:0;end
            SIGN_RESULT:begin alu_b=mul_acc;alu_sub=mul_negative;end
            default:begin end
        endcase
    end
    // One WORK_W carry adder with carry-in, shared by add/sub, abs and multiply.
    wire [WORK_W:0] sum_ext={1'b0,alu_a}+{1'b0,(alu_b^{WORK_W{alu_sub}})}+
                                                            {{WORK_W{1'b0}},alu_sub};
    wire [WORK_W-1:0] alu_result=sum_ext[WORK_W-1:0];
    wire [WORK_W-1:0] factor_next=mul_factor>>1;
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && (state==OUT_HOLD || state==ERROR_HOLD);
    assign m_index=(state==ERROR_HOLD)?3'd0:out_index;
    assign m_keep=(state==OUT_HOLD);
    assign m_last=(state==ERROR_HOLD || out_index==6);
    assign m_errors=errors;
    assign m_tag=tag_q;
    generate if(WIDTH<1 || WIDTH>32 || HEIGHT<1 || HEIGHT>32 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        binary_hu_moments_invalid_parameters__see_README invalid();
    end endgenerate
    always @(posedge clk)if(!rst)begin
        case(state)
            RAW_STORE:scratch[raw_index]<={{(WORK_W-RAW_W){1'b0}},raw[raw_index]};
            READ_A:scratch_q<=scratch[addr_a];
            READ_B:scratch_q<=scratch[addr_b];
            WRITE:scratch[addr_d]<=result;
            OUT_NUM:scratch_q<=scratch[out_num_addr];
            OUT_DEN:scratch_q<=scratch[out_den_addr];
            default:begin end
        endcase
    end
    integer k;
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;x<=0;y<=0;capture_count<=0;errors<=0;tag_q<=0;
            xx<=0;xy<=0;yy<=0;xxx<=0;xxy<=0;xyy<=0;yyy<=0;
            for(k=0;k<10;k=k+1)raw[k]<=0;
            raw_index<=0;pc<=0;out_index<=0;
            operand_a<=0;operand_b<=0;result<=0;mul_shift<=0;mul_factor<=0;mul_acc<=0;
            mul_step<=0;mul_negative<=0;m_numerator<=0;m_denominator<=1;m_area<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(capture_count==0)tag_q<=s_tag;
                for(k=0;k<10;k=k+1)begin
                    if(capture_count==0)raw[k]<=s_pixel?mono[k]:0;
                    else if(s_pixel)raw[k]<=raw[k]+mono[k];
                end
                errors<=capture_errors;
                capture_count<=capture_count+1'b1;
                if(capture_count==N-1)begin
                    m_area<=area_next[COUNT_W-1:0];raw_index<=0;pc<=0;out_index<=0;
                    if(capture_errors!=0 || area_next==0)begin
                        errors<=capture_errors|{3'b000,(area_next==0)};
                        m_numerator<=0;m_denominator<=1;state<=ERROR_HOLD;
                    end else state<=RAW_STORE;
                end else if(x==WX-1)begin
                    x<=0;y<=y+1'b1;xx<=0;xy<=0;xxx<=0;xxy<=0;xyy<=0;
                    yy<=yy+({{(2*L-YW){1'b0}},y}<<1)+1'b1;
                    yyy<=yyy+{{L{1'b0}},yy}+({{L{1'b0}},yy}<<1)+
                        {{(3*L-YW){1'b0}},y}+({{(3*L-YW){1'b0}},y}<<1)+1'b1;
                end else begin
                    x<=x+1'b1;
                    xx<=xx+({{(2*L-XW){1'b0}},x}<<1)+1'b1;
                    xxx<=xxx+{{L{1'b0}},xx}+({{L{1'b0}},xx}<<1)+
                        {{(3*L-XW){1'b0}},x}+({{(3*L-XW){1'b0}},x}<<1)+1'b1;
                    xy<=xy+y;
                    xxy<=xxy+({{L{1'b0}},xy}<<1)+y;
                    xyy<=xyy+yy;
                end
            end
            RAW_STORE:if(raw_index==9)begin state<=READ_A;end else raw_index<=raw_index+1'b1;
            READ_A:state<=READ_B;
            READ_B:begin operand_a<=$signed(scratch_q)<<<shift_a;state<=EXEC;end
            EXEC:if(op==2)begin
                operand_b<=shifted_b;mul_negative<=operand_a[WORK_W-1]^shifted_b[WORK_W-1];state<=ABS_A;
            end else begin result<=$signed(alu_result);state<=WRITE;end
            ABS_A:begin mul_shift<=alu_result;state<=ABS_B;end
            ABS_B:begin mul_factor<=alu_result;mul_acc<=0;mul_step<=0;state<=MUL;end
            MUL:begin
                mul_acc<=alu_result;mul_factor<=factor_next;
                // Never shift a magnitude after the last significant factor bit.
                if(factor_next!=0)mul_shift<=mul_shift<<1;
                if(mul_step==WORK_W-1)state<=SIGN_RESULT;
                else mul_step<=mul_step+1'b1;
            end
            SIGN_RESULT:begin result<=$signed(alu_result);state<=WRITE;end
            WRITE:if(pc==78)begin out_index<=0;state<=OUT_NUM;end
                  else begin pc<=pc+1'b1;state<=READ_A;end
            OUT_NUM:state<=OUT_DEN;
            OUT_DEN:begin m_numerator<=scratch_q;state<=OUT_LOAD;end
            OUT_LOAD:begin m_denominator<=scratch_q;state<=OUT_HOLD;end
            OUT_HOLD:if(m_ready)begin
                if(out_index==6)begin
                    state<=CAPTURE;capture_count<=0;x<=0;y<=0;errors<=0;
                    xx<=0;xy<=0;yy<=0;xxx<=0;xxy<=0;xyy<=0;yyy<=0;
                end else begin out_index<=out_index+1'b1;state<=OUT_NUM;end
            end
            ERROR_HOLD:if(m_ready)begin
                state<=CAPTURE;capture_count<=0;x<=0;y<=0;errors<=0;
                xx<=0;xy<=0;yy<=0;xxx<=0;xxy<=0;xyy<=0;yyy<=0;
            end
            default:begin state<=CAPTURE;capture_count<=0;errors<=0;x<=0;y<=0;
                xx<=0;xy<=0;yy<=0;xxx<=0;xxy<=0;xyy<=0;yyy<=0;end
        endcase
    end
endmodule
`default_nettype wire
