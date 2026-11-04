// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module congruence_merge #(parameter integer W=8,TAG_W=8)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [W-1:0] s_a,s_b,
    input wire [W-1:0] s_m,s_n,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [2*W-1:0] m_solution,m_period,
    output reg [2:0] m_status,output wire [TAG_W-1:0] m_tag
);
    localparam integer DCW=W<=2?1:$clog2(W);
    localparam [2:0] IDLE=0,DIVIDE=1,RETURN=2,ORBIT=3,FINISH=4,OUTPUT=5;
    generate if(W<1 || W>16 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        congruence_merge_invalid_parameters__see_README invalid();
    end endgenerate
    reg [2:0] state;
    reg [TAG_W-1:0] tag;
    reg negative_a,negative_b;
    reg [W-1:0] modulus_m,modulus_n,magnitude_b,r1,r2,step,start_residue,orbit_residue;
    reg [W-1:0] dividend;
    reg [W:0] remainder;
    reg [DCW-1:0] div_count;
    reg [1:0] job;
    reg [2*W-1:0] candidate;
    reg found;
    wire [W-1:0] magnitude_a=s_a[W-1]?(~s_a[W-1:0]+1'b1):s_a;
    wire [W-1:0] input_magnitude_b=s_b[W-1]?(~s_b[W-1:0]+1'b1):s_b;
    wire [W-1:0] divisor=job==0?modulus_m:modulus_n;
    wire [W:0] trial={remainder[W-1:0],dividend[W-1]};
    wire [W:0] next_remainder=trial>={1'b0,divisor}?trial-{1'b0,divisor}:trial;
    wire [W:0] residue_sum={1'b0,orbit_residue}+{1'b0,step};
    wire [W:0] residue_reduced=residue_sum>={1'b0,modulus_n}?
                                  residue_sum-{1'b0,modulus_n}:residue_sum;
    wire [2*W-1:0] next_candidate=candidate+{{W{1'b0}},modulus_m};
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==OUTPUT;
    assign m_tag=tag;
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;tag<=0;m_solution<=0;m_period<=0;m_status<=0;
        end else case(state)
            IDLE:if(s_valid)begin
                tag<=s_tag;negative_a<=s_a[W-1];negative_b<=s_b[W-1];
                modulus_m<=s_m;modulus_n<=s_n;magnitude_b<=input_magnitude_b;
                m_solution<=0;m_period<=0;m_status<={1'b0,s_n==0,s_m==0};
                if(s_m==0 || s_n==0)state<=OUTPUT;
                else begin dividend<=magnitude_a;remainder<=0;div_count<=0;job<=0;state<=DIVIDE;end
            end
            DIVIDE:begin
                dividend<=dividend<<1;remainder<=next_remainder;
                if(div_count==W-1)state<=RETURN;
                else div_count<=div_count+1'b1;
            end
            RETURN:begin
                remainder<=0;div_count<=0;
                case(job)
                0:begin
                    r1<=negative_a && remainder!=0?modulus_m-remainder[W-1:0]:remainder[W-1:0];
                    dividend<=magnitude_b;job<=1;state<=DIVIDE;
                end
                1:begin
                    r2<=negative_b && remainder!=0?modulus_n-remainder[W-1:0]:remainder[W-1:0];
                    dividend<=modulus_m;job<=2;state<=DIVIDE;
                end
                2:begin step<=remainder[W-1:0];dividend<=r1;job<=3;state<=DIVIDE;end
                3:begin
                    start_residue<=remainder[W-1:0];orbit_residue<=remainder[W-1:0];
                    candidate<={{W{1'b0}},r1};found<=0;state<=ORBIT;
                end
                endcase
            end
            ORBIT:begin
                if(!found && orbit_residue==r2)begin found<=1;m_solution<=candidate;end
                candidate<=next_candidate;orbit_residue<=residue_reduced[W-1:0];
                if(residue_reduced[W-1:0]==start_residue)begin
                    m_period<=next_candidate;state<=FINISH;
                end
            end
            FINISH:begin
                if(found)m_period<=m_period-{{W{1'b0}},r1};
                else begin m_status<=4;m_solution<=0;m_period<=0;end
                state<=OUTPUT;
            end
            OUTPUT:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
