// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module signed8_layer_norm #(
    parameter integer MAX_LEN=64, FRAC=12, TAG_W=16,
    localparam integer C=(MAX_LEN<2)?0:$clog2(MAX_LEN),
    localparam integer IW=(C<1)?1:C,
    localparam integer CW=(MAX_LEN<2)?1:$clog2(MAX_LEN+1)
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire [1:0] c_op,input wire [15:0] c_index,
    input wire signed [15:0] c_gamma,c_beta,input wire [4:0] c_shift,
    output wire c_rsp_valid,input wire c_rsp_ready,output reg [1:0] c_error,
    input wire cmd_valid,output wire cmd_ready,
    input wire [15:0] cmd_len,cmd_epsilon,input wire [TAG_W-1:0] cmd_tag,
    input wire s_valid,output wire s_ready,
    input wire signed [7:0] s_data,input wire s_last,
    output wire m_valid,input wire m_ready,
    output reg signed [7:0] m_data,output wire [15:0] m_index,
    output wire m_last,output reg [2:0] m_error,
    output reg m_clip,m_inexact,output reg m_degenerate,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer SW=8+C,QW=16+C,UW=9+C,EW=18+2*C;
    localparam integer RF=FRAC+2,RN=(EW+2*RF+1)/2,BW=RN+1;
    localparam integer AW=UW+RF,NW=FRAC+C+2;
    localparam [3:0] IDLE=0,CHECK=1,CAPTURE=2,PREPARE=3,
        MUL_OFFER=4,MUL_WAIT=5,ROOT_OFFER=6,ROOT_WAIT=7,
        READ=8,CENTER=9,DIV_OFFER=10,DIV_WAIT=11,AFFINE=12,
        QUANT_OFFER=13,QUANT_WAIT=14,EMIT=15;
    generate if(MAX_LEN<1 || MAX_LEN>256 || FRAC<0 || FRAC>16 ||
                TAG_W<1 || TAG_W>32)begin:g_invalid
        signed8_layer_norm_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    reg [3:0] state;
    reg c_rsp_pending;
    reg [CW-1:0] length;
    reg [IW-1:0] index;
    reg [15:0] epsilon;
    reg signed [SW-1:0] sum;
    reg [QW-1:0] sumsq;
    reg [MAX_LEN-1:0] affine_valid;
    reg [36:0] affine_mem[0:MAX_LEN-1];
    reg signed [7:0] samples[0:MAX_LEN-1];
    reg signed [7:0] sample_q;
    reg [36:0] affine_q;
    reg signed [UW-1:0] centered_sample;
    reg [EW-1:0] moment,centered_energy,radicand;
    reg [BW-1:0] root_q;
    reg signed [NW-1:0] norm_q;
    reg [2:0] mul_phase;
    reg [31:0] mul_a,mul_b;
    reg mul_negative;
    reg signed [63:0] scaled_q;
    wire mul_ready,mul_valid;
    wire [63:0] mul_product;
    wire root_ready,root_valid;
    wire [BW-1:0] root_data;
    wire [1:0] root_user;
    wire div_ready,div_valid;
    wire [NW-1:0] div_data;
    wire [1:0] div_user;
    wire quant_ready,quant_valid,quant_clip,quant_inexact;
    wire [31:0] quant_data;
    wire quant_tag;
    wire signed [15:0] input_square=s_data*s_data;
    wire [QW-1:0] extended_square={{(QW-16){1'b0}},$unsigned(input_square)};
    wire signed [SW-1:0] extended_sample={{(SW-8){s_data[7]}},s_data};
    wire [SW-1:0] abs_sum=sum[SW-1]?(~sum+1'b1):sum;
    wire [NW-1:0] abs_norm=norm_q[NW-1]?(~norm_q+1'b1):norm_q;
    wire signed [15:0] gamma=affine_q[15:0];
    wire [15:0] abs_gamma=gamma[15]?(~gamma+1'b1):gamma;
    wire signed [UW:0] nx=$signed({1'b0,length})*sample_q;
    wire signed [UW:0] u_full=nx-$signed({{(UW+1-SW){sum[SW-1]}},sum});
    wire signed [AW-1:0] scaled_u={centered_sample,{RF{1'b0}}};
    wire signed [32:0] biased=$signed({quant_data[31],quant_data})+
        $signed({{17{affine_q[31]}},affine_q[31:16]});
    wire [EW-1:0] t_next=centered_energy+mul_product[EW-1:0];
    assign c_rsp_valid=!rst && c_rsp_pending;
    assign c_ready=!rst && state==IDLE && !c_rsp_pending;
    assign cmd_ready=c_ready && !c_valid;
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==EMIT;
    assign m_index={{(16-IW){1'b0}},index};
    assign m_last=(m_error!=0) || index==length-1'b1;

    // Capture/configuration and processing own disjoint memory phases.
    always @(posedge clk)begin
        if(!rst)begin
            if(c_valid && c_ready && c_op==0 && c_index<MAX_LEN)
                affine_mem[c_index[IW-1:0]]<={c_shift,c_beta,c_gamma};
            if(s_valid && s_ready) samples[index]<=s_data;
            if(state==READ)begin
                sample_q<=samples[index];affine_q<=affine_mem[index];
            end
        end
    end
    img_hist_serial_multiply #(.A_W(32),.B_W(32)) shared_product(
        .clk(clk),.rst_n(!rst),.clk_en(1'b1),
        .s_valid(!rst && state==MUL_OFFER),.s_ready(mul_ready),
        .s_a(mul_a),.s_b(mul_b),.m_valid(mul_valid),
        .m_ready(!rst && state==MUL_WAIT),.m_product(mul_product));
    fp_sqrt_iter #(.IN_W(EW),.FB(RF)) root_engine(
        .clk(clk),.rst_n(!rst),.s_tdata(radicand),
        .s_tvalid(!rst && state==ROOT_OFFER),.s_tready(root_ready),
        .m_tdata(root_data),.m_tuser(root_user),.m_tvalid(root_valid),
        .m_tready(!rst && state==ROOT_WAIT));
    fp_div_iter #(.AW(AW),.BW(BW),.FB(FRAC),.OUT_W(NW)) divide_engine(
        .clk(clk),.rst_n(!rst),.s_tdata({root_q,scaled_u}),
        .s_tvalid(!rst && state==DIV_OFFER),.s_tready(div_ready),
        .m_tdata(div_data),.m_tuser(div_user),.m_tvalid(div_valid),
        .m_tready(!rst && state==DIV_WAIT));
    stream_requantize #(.IN_W(64),.OUT_W(32),.TAG_W(1)) requantizer(
        .clk(clk),.rst(rst),.s_valid(!rst && state==QUANT_OFFER),
        .s_ready(quant_ready),.s_data(scaled_q),
        .s_shift({2'b00,affine_q[36:32]}),.s_tag(1'b0),
        .m_valid(quant_valid),.m_ready(!rst && state==QUANT_WAIT),
        .m_data(quant_data),.m_clip(quant_clip),.m_inexact(quant_inexact),
        .m_tag(quant_tag));

    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;c_rsp_pending<=0;c_error<=0;affine_valid<=0;
            length<=0;index<=0;epsilon<=0;sum<=0;sumsq<=0;
            m_data<=0;m_error<=0;m_clip<=0;m_inexact<=0;m_degenerate<=0;m_tag<=0;
            moment<=0;centered_energy<=0;radicand<=0;root_q<=0;norm_q<=0;
            mul_a<=0;mul_b<=0;mul_phase<=0;mul_negative<=0;scaled_q<=0;centered_sample<=0;
        end else begin
            if(c_rsp_valid && c_rsp_ready)c_rsp_pending<=0;
            case(state)
                IDLE:begin
                    if(c_valid && c_ready)begin
                        c_rsp_pending<=1;c_error<=0;
                        case(c_op)
                            0:if(c_index<MAX_LEN)affine_valid[c_index[IW-1:0]]<=1;
                              else c_error<=1;
                            1:affine_valid<=0;
                            default:c_error<=2;
                        endcase
                    end else if(cmd_valid && cmd_ready)begin
                        index<=0;sum<=0;sumsq<=0;epsilon<=cmd_epsilon;
                        m_tag<=cmd_tag;m_data<=0;m_error<=0;m_clip<=0;m_inexact<=0;m_degenerate<=0;
                        if(cmd_len==0 || cmd_len>MAX_LEN)begin
                            length<=0;m_error<=1;state<=EMIT;
                        end else begin length<=cmd_len[CW-1:0];state<=CHECK;end
                    end
                end
                CHECK:begin
                    if(!affine_valid[index])begin index<=0;m_error<=2;state<=EMIT;end
                    else if(index==length-1'b1)begin index<=0;state<=CAPTURE;end
                    else index<=index+1'b1;
                end
                CAPTURE:if(s_valid)begin
                    sum<=sum+extended_sample;sumsq<=sumsq+extended_square;
                    if(s_last!=(index==length-1'b1))begin
                        index<=0;m_error<=3;state<=EMIT;
                    end else if(s_last)begin index<=0;state<=PREPARE;end
                    else index<=index+1'b1;
                end
                PREPARE:begin
                    mul_a<={{(32-CW){1'b0}},length};mul_b<={{(32-QW){1'b0}},sumsq};
                    mul_phase<=0;state<=MUL_OFFER;
                end
                MUL_OFFER:if(mul_ready)state<=MUL_WAIT;
                MUL_WAIT:if(mul_valid)begin
                    case(mul_phase)
                        0:begin
                            moment<=mul_product[EW-1:0];
                            mul_a<={{(32-SW){1'b0}},abs_sum};mul_b<={{(32-SW){1'b0}},abs_sum};
                            mul_phase<=1;state<=MUL_OFFER;
                        end
                        1:begin
                            centered_energy<=moment-mul_product[EW-1:0];
                            mul_a<={{(32-CW){1'b0}},length};mul_b<={{(32-CW){1'b0}},length};
                            mul_phase<=2;state<=MUL_OFFER;
                        end
                        2:begin
                            mul_a<=mul_product[31:0];mul_b<={16'd0,epsilon};
                            mul_phase<=3;state<=MUL_OFFER;
                        end
                        3:begin
                            radicand<=t_next;m_degenerate<=(t_next==0);
                            state<=(t_next==0)?READ:ROOT_OFFER;
                        end
                        4:begin
                            scaled_q<=mul_negative?-$signed(mul_product):$signed(mul_product);
                            state<=QUANT_OFFER;
                        end
                        default:begin index<=0;m_data<=0;m_error<=4;
                            m_clip<=0;m_inexact<=0;m_degenerate<=0;state<=EMIT;end
                    endcase
                end
                ROOT_OFFER:if(root_ready)state<=ROOT_WAIT;
                ROOT_WAIT:if(root_valid)begin root_q<=root_data;state<=READ;end
                READ:state<=CENTER;
                CENTER:begin
                    centered_sample<=u_full[UW-1:0];
                    if(m_degenerate)begin norm_q<=0;state<=AFFINE;end
                    else state<=DIV_OFFER;
                end
                DIV_OFFER:if(div_ready)state<=DIV_WAIT;
                DIV_WAIT:if(div_valid)begin
                    if(div_user!=0)begin index<=0;m_data<=0;m_error<=4;
                        m_clip<=0;m_inexact<=0;m_degenerate<=0;state<=EMIT;end
                    else begin norm_q<=div_data;state<=AFFINE;end
                end
                AFFINE:begin
                    mul_a<={{(32-NW){1'b0}},abs_norm};mul_b<={16'd0,abs_gamma};
                    mul_negative<=norm_q[NW-1]^gamma[15];mul_phase<=4;state<=MUL_OFFER;
                end
                QUANT_OFFER:if(quant_ready)state<=QUANT_WAIT;
                QUANT_WAIT:if(quant_valid)begin
                    m_data<=biased>127?8'sd127:biased < -128?8'h80:biased[7:0];
                    m_clip<=quant_clip || biased>127 || biased < -128;
                    m_inexact<=quant_inexact;state<=EMIT;
                end
                EMIT:if(m_ready)begin
                    if(m_last)state<=IDLE;
                    else begin index<=index+1'b1;state<=READ;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
