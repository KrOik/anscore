// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module exact_integer_charpoly #(
    parameter integer N=4, DATA_W=8, TAG_W=8,
    localparam integer NN=(N<1)?1:N,
    localparam integer L=$clog2(NN),
    localparam integer WORK_W=NN*(DATA_W-1)+(NN+1)*L+3,
    localparam integer FACT_N=(NN==1)?1:(NN==2)?2:(NN==3)?6:(NN==4)?24:
                              (NN==5)?120:(NN==6)?720:(NN==7)?5040:40320,
    localparam integer COEFF_W=NN*(DATA_W-1)+$clog2(FACT_N+1)+1,
    localparam integer K=$clog2(NN+1), CW=$clog2(NN*NN+2),
    localparam integer SW=($clog2(COEFF_W)<1)?1:$clog2(COEFF_W)
)(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire signed [DATA_W-1:0] s_data,
    input wire s_keep,s_last,s_bad,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire signed [COEFF_W-1:0] m_coeff,
    output wire [K-1:0] m_index,
    output wire m_keep,m_last,
    output wire [2:0] m_errors,
    output wire [TAG_W-1:0] m_tag
);
    localparam [4:0] IDLE=0,CAPTURE=1,ERROR_HOLD=2,BASE_READ=3,BASE_WRITE=4,
        G0=5,G1=6,V_INIT_READ=7,V_INIT_WRITE=8,DOT_READ=9,DOT_LOAD=10,
        MUL_NARROW=11,DOT_ACC=12,CONV_READ=13,CONV_LOAD=14,MUL_WIDE=15,
        CONV_ACC=16,OUT_FETCH=17,OUT_HOLD=18;
    reg [4:0] state;
    reg [CW-1:0] count;
    reg [2:0] errors;
    reg [TAG_W-1:0] tag_q;
    reg [K-1:0] m,r,i,j;
    reg [SW-1:0] mul_step;
    reg vec_bank,coeff_bank,power_mode,mul_negative;
    reg signed [DATA_W-1:0] a_mem[0:NN*NN-1],a_q;
    reg signed [WORK_W-1:0] v0_mem[0:NN-1],v1_mem[0:NN-1],g_mem[0:NN];
    reg signed [WORK_W-1:0] v0_q,v1_q,g_q,dot_acc;
    reg signed [COEFF_W-1:0] q0_mem[0:NN],q1_mem[0:NN],q0_q,q1_q;
    reg [WORK_W-1:0] mul_shift,mul_acc;
    reg [COEFF_W-1:0] mul_factor;
    wire signed [WORK_W-1:0] v_q=vec_bank?v1_q:v0_q;
    wire signed [COEFF_W-1:0] q_q=coeff_bank?q1_q:q0_q;
    wire signed [WORK_W-1:0] a_work={{(WORK_W-DATA_W){a_q[DATA_W-1]}},a_q};
    wire signed [COEFF_W-1:0] a_coeff={{(COEFF_W-DATA_W){a_q[DATA_W-1]}},a_q};
    // One shared WORK unary sign path, one shared COEFF unary sign path.
    wire signed [WORK_W-1:0] neg_source=(state==BASE_WRITE || state==G1)?a_work:
        (state==DOT_LOAD)?v_q:(state==CONV_LOAD)?g_q:$signed(mul_acc);
    wire signed [WORK_W-1:0] neg_work=-neg_source;
    wire signed [COEFF_W-1:0] factor_source=(state==DOT_LOAD)?a_coeff:q_q;
    wire signed [COEFF_W-1:0] neg_coeff=-factor_source;
    wire [WORK_W-1:0] work_magnitude=neg_source[WORK_W-1]?neg_work:neg_source;
    wire [COEFF_W-1:0] factor_magnitude=factor_source[COEFF_W-1]?neg_coeff:factor_source;
    wire signed [WORK_W-1:0] signed_product=mul_negative?neg_work:$signed(mul_acc);
    wire mul_phase=(state==MUL_NARROW || state==MUL_WIDE);
    // MUL and ACC never overlap: one explicitly multiplexed wide adder.
    wire [WORK_W-1:0] add_a=mul_phase?mul_acc:$unsigned(dot_acc);
    wire [WORK_W-1:0] add_b=mul_phase?(mul_factor[0]?mul_shift:{WORK_W{1'b0}}):$unsigned(signed_product);
    wire [WORK_W-1:0] add_total=add_a+add_b;
    wire signed [WORK_W-1:0] dot_total=$signed(add_total);
    wire [COEFF_W-1:0] factor_remaining=mul_factor>>1;
    wire [K-1:0] conv_limit=(i<m)?i:m-1'b1;
    wire [CW-1:0] count_next=(s_keep && count<NN*NN+1)?count+1'b1:count;
    wire [2:0] accepted_errors=errors|{s_bad,(s_keep && count>=NN*NN),1'b0};
    wire [2:0] final_errors=accepted_errors|{2'b00,(count_next<NN*NN)};

    assign s_ready=!rst && (state==IDLE || state==CAPTURE);
    assign m_valid=!rst && (state==OUT_HOLD || state==ERROR_HOLD);
    assign m_coeff=(state==ERROR_HOLD)?{COEFF_W{1'b0}}:q_q;
    assign m_index=(state==ERROR_HOLD)?{K{1'b0}}:i;
    assign m_keep=(state==OUT_HOLD);
    assign m_last=(state==ERROR_HOLD || (state==OUT_HOLD && i==NN));
    assign m_errors=errors;
    assign m_tag=tag_q;

    generate if(N<1 || N>8 || DATA_W<2 || DATA_W>12 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        exact_integer_charpoly_invalid_parameters__see_README invalid();
    end endgenerate

    // All six banks have exactly one enabled synchronous read OR write per cycle.
    // Read-q and payload arrays are intentionally unreset.
    always @(posedge clk)if(!rst)begin
        case(state)
            IDLE,CAPTURE:if(s_valid && s_keep && count<NN*NN)a_mem[count]<=s_data;
            BASE_READ:a_q<=a_mem[NN*NN-1];
            G0:a_q<=a_mem[(NN-m)*NN+(NN-m)];
            V_INIT_READ:a_q<=a_mem[(NN-m+1+i)*NN+(NN-m)];
            DOT_READ:a_q<=a_mem[power_mode?((NN-m+1+i)*NN+(NN-m+1+j)):
                                                       ((NN-m)*NN+(NN-m+1+j))];
            default:begin end
        endcase
        case(state)
            V_INIT_WRITE:v0_mem[i]<=a_work;
            DOT_READ:if(vec_bank)v1_q<=v1_mem[j];else v0_q<=v0_mem[j];
            DOT_ACC:if(power_mode && j==m-2)begin
                if(vec_bank)v0_mem[i]<=dot_total;else v1_mem[i]<=dot_total;
            end
            default:begin end
        endcase
        case(state)
            G0:g_mem[0]<={{(WORK_W-1){1'b0}},1'b1};
            G1:g_mem[1]<=neg_work;
            DOT_ACC:if(!power_mode && j==m-2)g_mem[r]<=dot_total;
            CONV_READ:g_q<=g_mem[i-j];
            default:begin end
        endcase
        case(state)
            BASE_READ:q0_mem[0]<={{(COEFF_W-1){1'b0}},1'b1};
            BASE_WRITE:q0_mem[1]<=neg_work[COEFF_W-1:0];
            CONV_READ:if(coeff_bank)q1_q<=q1_mem[j];else q0_q<=q0_mem[j];
            CONV_ACC:if(j==conv_limit)begin
                if(coeff_bank)q0_mem[i]<=dot_total[COEFF_W-1:0];
                else q1_mem[i]<=dot_total[COEFF_W-1:0];
            end
            OUT_FETCH:if(coeff_bank)q1_q<=q1_mem[i];else q0_q<=q0_mem[i];
            default:begin end
        endcase
    end

    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;count<=0;errors<=0;tag_q<=0;m<=0;r<=0;i<=0;j<=0;
            mul_step<=0;vec_bank<=0;coeff_bank<=0;power_mode<=0;mul_negative<=0;
            dot_acc<=0;mul_shift<=0;mul_acc<=0;mul_factor<=0;
        end else case(state)
            IDLE,CAPTURE:if(s_valid)begin
                if(state==IDLE)tag_q<=s_tag;
                count<=count_next;errors<=accepted_errors;
                if(s_last)begin
                    errors<=final_errors;
                    state<=(final_errors!=0)?ERROR_HOLD:BASE_READ;
                end else state<=CAPTURE;
            end
            BASE_READ:begin
                coeff_bank<=0;vec_bank<=0;m<=1;r<=0;i<=0;j<=0;
                dot_acc<=0;state<=BASE_WRITE;
            end
            BASE_WRITE:begin
                if(NN==1)begin i<=0;state<=OUT_FETCH;end
                else begin m<=2;state<=G0;end
            end
            G0:begin vec_bank<=0;i<=0;j<=0;r<=2;dot_acc<=0;power_mode<=0;state<=G1;end
            G1:begin i<=0;state<=V_INIT_READ;end
            V_INIT_READ:state<=V_INIT_WRITE;
            V_INIT_WRITE:begin
                if(i==m-2)begin i<=0;j<=0;dot_acc<=0;power_mode<=0;state<=DOT_READ;end
                else begin i<=i+1'b1;state<=V_INIT_READ;end
            end
            DOT_READ:state<=DOT_LOAD;
            DOT_LOAD:begin
                mul_shift<=work_magnitude;mul_factor<=factor_magnitude;mul_acc<=0;mul_step<=0;
                mul_negative<=a_q[DATA_W-1]^v_q[WORK_W-1]^(!power_mode);
                state<=MUL_NARROW;
            end
            MUL_NARROW,MUL_WIDE:begin
                mul_acc<=add_total;mul_factor<=factor_remaining;
                // The full product bound proves every used shift fits WORK_W.
                // Freeze after the last nonzero factor bit; retain fixed cycle count.
                if(factor_remaining!=0)mul_shift<=mul_shift<<1;
                if((state==MUL_NARROW && mul_step==DATA_W-1) ||
                   (state==MUL_WIDE && mul_step==COEFF_W-1))
                    state<=(state==MUL_NARROW)?DOT_ACC:CONV_ACC;
                else mul_step<=mul_step+1'b1;
            end
            DOT_ACC:begin
                if(j!=m-2)begin dot_acc<=dot_total;j<=j+1'b1;state<=DOT_READ;end
                else begin
                    dot_acc<=0;j<=0;
                    if(power_mode)begin
                        if(i!=m-2)begin i<=i+1'b1;state<=DOT_READ;end
                        else begin i<=0;vec_bank<=~vec_bank;power_mode<=0;r<=r+1'b1;state<=DOT_READ;end
                    end else if(r<m)begin power_mode<=1;i<=0;state<=DOT_READ;end
                    else begin i<=0;state<=CONV_READ;end
                end
            end
            CONV_READ:state<=CONV_LOAD;
            CONV_LOAD:begin
                mul_shift<=work_magnitude;mul_factor<=factor_magnitude;mul_acc<=0;mul_step<=0;
                mul_negative<=g_q[WORK_W-1]^q_q[COEFF_W-1];state<=MUL_WIDE;
            end
            CONV_ACC:begin
                if(j!=conv_limit)begin dot_acc<=dot_total;j<=j+1'b1;state<=CONV_READ;end
                else begin
                    dot_acc<=0;j<=0;
                    if(i<m)begin i<=i+1'b1;state<=CONV_READ;end
                    else begin
                        coeff_bank<=~coeff_bank;i<=0;
                        if(m<NN)begin m<=m+1'b1;state<=G0;end
                        else state<=OUT_FETCH;
                    end
                end
            end
            OUT_FETCH:state<=OUT_HOLD;
            OUT_HOLD:if(m_ready)begin
                if(i==NN)begin state<=IDLE;count<=0;errors<=0;end
                else begin i<=i+1'b1;state<=OUT_FETCH;end
            end
            ERROR_HOLD:if(m_ready)begin state<=IDLE;count<=0;errors<=0;end
            default:begin state<=IDLE;count<=0;errors<=0;end
        endcase
    end
endmodule
`default_nettype wire
