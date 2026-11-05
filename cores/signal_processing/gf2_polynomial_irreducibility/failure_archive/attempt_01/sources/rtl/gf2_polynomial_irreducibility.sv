// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module gf2_polynomial_irreducibility #(
    parameter integer DEGREE=16,
    parameter integer TAG_W=8
)(
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire [DEGREE-1:0] s_poly,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg m_irreducible,
    output reg [1:0] m_kind,
    output reg [((DEGREE>1)?$clog2(DEGREE+1):1)-1:0] m_check_index,
    output reg [DEGREE-1:0] m_delta,
    output reg [DEGREE:0] m_witness_gcd,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer IW=(DEGREE>1)?$clog2(DEGREE+1):1;
    localparam integer CW=(DEGREE>1)?$clog2(DEGREE):1;
    localparam [2:0] IDLE=0, SQ_LOAD=1, SQ_STEP=2, SQ_CHECK=3,
                     GCD_LOAD=4, GCD_STEP=5, HOLD=6;
    localparam [DEGREE-1:0] X_BITS=2;
    function automatic [DEGREE:0] checkpoint_mask;
        integer q,j;
        reg prime;
        begin
            checkpoint_mask=0;
            for(q=2;q<=DEGREE;q=q+1)begin
                prime=1;
                for(j=2;j<q;j=j+1)if(q%j==0)prime=0;
                if(prime && DEGREE%q==0)checkpoint_mask[DEGREE/q]=1;
            end
        end
    endfunction
    localparam [DEGREE:0] CHECKPOINTS=checkpoint_mask();
    generate if(DEGREE<1 || DEGREE>64 || TAG_W<1 || TAG_W>32)begin: bad_parameters
        gf2_polynomial_irreducibility_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    reg [2:0] state;
    reg [DEGREE-1:0] polynomial,h,a,b,acc;
    reg [DEGREE:0] u,v;
    reg [TAG_W-1:0] tag;
    reg [IW-1:0] round_index;
    reg [CW-1:0] square_left;
    reg [IW-1:0] degree_u,degree_v;
    integer scan;
    always @*begin
        degree_u=0;degree_v=0;
        for(scan=0;scan<=DEGREE;scan=scan+1)begin
            if(u[scan])degree_u=scan[IW-1:0];
            if(v[scan])degree_v=scan[IW-1:0];
        end
    end
    wire [DEGREE-1:0] x_mod_p=(DEGREE==1)?polynomial:X_BITS;
    wire [DEGREE-1:0] next_acc=acc ^ (b[0]?a:{DEGREE{1'b0}});
    wire [DEGREE-1:0] next_a=(a<<1) ^ (a[DEGREE-1]?polynomial:{DEGREE{1'b0}});
    wire [IW-1:0] difference=degree_u-degree_v;
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==HOLD;
    assign m_tag=tag;
    always @(posedge clk)begin
        if(rst)state<=IDLE;
        else case(state)
            IDLE:if(s_valid)begin
                polynomial<=s_poly;tag<=s_tag;
                // x mod (x+c)=c. Bit one is not representable at DEGREE=1.
                h<=(DEGREE==1)?s_poly:X_BITS;
                round_index<=1;state<=SQ_LOAD;
            end
            SQ_LOAD:begin
                a<=h;b<=h;acc<=0;square_left<=DEGREE-1;
                state<=SQ_STEP;
            end
            SQ_STEP:begin
                a<=next_a;b<=b>>1;acc<=next_acc;
                if(square_left==0)begin h<=next_acc;state<=SQ_CHECK;end
                else square_left<=square_left-1'b1;
            end
            SQ_CHECK:begin
                if(CHECKPOINTS[round_index])state<=GCD_LOAD;
                else if(round_index==DEGREE)begin
                    m_irreducible<=h==x_mod_p;
                    m_kind<=(h==x_mod_p)?0:2;
                    m_check_index<=round_index;m_delta<=h^x_mod_p;
                    m_witness_gcd<=1;state<=HOLD;
                end else begin round_index<=round_index+1'b1;state<=SQ_LOAD;end
            end
            GCD_LOAD:begin
                u<={1'b1,polynomial};v<={1'b0,h^x_mod_p};
                state<=GCD_STEP;
            end
            GCD_STEP:begin
                if(v==0)begin
                    if(u!=1)begin
                        m_irreducible<=0;m_kind<=1;
                        m_check_index<=round_index;m_delta<=h^x_mod_p;
                        m_witness_gcd<=u;state<=HOLD;
                    end else begin round_index<=round_index+1'b1;state<=SQ_LOAD;end
                end else if(u==0 || degree_u<degree_v)begin u<=v;v<=u;end
                else u<=u^(v<<difference);
            end
            HOLD:if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
