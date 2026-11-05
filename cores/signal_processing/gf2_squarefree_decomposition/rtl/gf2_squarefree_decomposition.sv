// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module gf2_squarefree_decomposition #(
    parameter integer DEGREE=16,
    parameter integer TAG_W=8
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [DEGREE-1:0] s_poly,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [DEGREE:0] m_factor,
    output wire [((DEGREE>1)?$clog2(DEGREE+1):1)-1:0] m_multiplicity,
    output wire [((DEGREE>1)?$clog2(DEGREE+1):1)-1:0] m_degree,
    output wire m_last,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer IW=(DEGREE>1)?$clog2(DEGREE+1):1;
    localparam integer LMAX=(DEGREE<2)?0:$clog2(DEGREE+1)-1;
    localparam integer LW=(LMAX>0)?$clog2(LMAX+1):1;
    localparam [2:0] IDLE=0,INITIALIZE=1,GCD_STEP=2,DIV_STEP=3,
                     LAYER=4,HOLD=5;
    generate if(DEGREE<1 || DEGREE>64 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        gf2_squarefree_decomposition_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    reg [2:0] state;
    // operation: GCD 0=initial,1=layer; DIV 0=initial W,1=pending Z,2=next C.
    reg [1:0] operation;
    reg [DEGREE:0] f,c,w,y,z,u,v,q;
    reg [IW-1:0] iteration;
    reg [LW-1:0] level;
    reg [TAG_W-1:0] tag;
    reg [IW-1:0] degree_u,degree_v,degree_z;
    integer scan;
    always @*begin
        degree_u=0;degree_v=0;degree_z=0;
        for(scan=0;scan<=DEGREE;scan=scan+1)begin
            if(u[scan])degree_u=scan[IW-1:0];
            if(v[scan])degree_v=scan[IW-1:0];
            if(z[scan])degree_z=scan[IW-1:0];
        end
    end
    wire [DEGREE:0] derivative,square_root;
    genvar k;
    generate for(k=0;k<=DEGREE;k=k+1)begin:coefficient_wiring
        if(k<DEGREE && k%2==0)assign derivative[k]=f[k+1];
        else assign derivative[k]=1'b0;
        if(2*k<=DEGREE)assign square_root[k]=c[2*k];
        else assign square_root[k]=1'b0;
    end endgenerate
    wire [IW-1:0] difference=degree_u-degree_v;
    wire [DEGREE:0] shifted_divisor=v<<difference;
    wire [DEGREE:0] quotient_monomial={{DEGREE{1'b0}},1'b1}<<difference;
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==HOLD;
    assign m_factor=z;
    assign m_multiplicity=iteration<<level;
    assign m_degree=degree_z;
    assign m_last=w==1 && c==1;
    assign m_tag=tag;

    always @(posedge clk)begin
        if(rst)state<=IDLE;
        else case(state)
            IDLE:if(s_valid)begin
                f<={1'b1,s_poly};tag<=s_tag;
                iteration<=1;level<=0;state<=INITIALIZE;
            end
            INITIALIZE:begin
                u<=f;v<=derivative;operation<=0;state<=GCD_STEP;
            end
            GCD_STEP:begin
                if(v==0)begin
                    if(operation==0)begin
                        c<=u;u<=f;v<=u;q<=0;operation<=0;
                    end else begin
                        y<=u;u<=w;v<=u;q<=0;operation<=1;
                    end
                    state<=DIV_STEP;
                end else if(u==0 || degree_u<degree_v)begin
                    u<=v;v<=u;
                end else u<=u^shifted_divisor;
            end
            DIV_STEP:begin
                if(u==0 || degree_u<degree_v)begin
                    case(operation)
                        0:begin w<=q;state<=LAYER;end
                        1:begin
                            z<=q;u<=c;v<=y;q<=0;operation<=2;
                        end
                        2:begin
                            // Finish the C/Y lookahead before exposing pending Z.
                            c<=q;w<=y;
                            if(z!=1)state<=HOLD;
                            else begin iteration<=iteration+1'b1;state<=LAYER;end
                        end
                        default:state<=IDLE;
                    endcase
                end else begin
                    u<=u^shifted_divisor;q<=q^quotient_monomial;
                end
            end
            LAYER:begin
                if(w!=1)begin
                    u<=w;v<=c;operation<=1;state<=GCD_STEP;
                end else if(c!=1)begin
                    f<=square_root;level<=level+1'b1;iteration<=1;
                    state<=INITIALIZE;
                end else state<=IDLE;
            end
            HOLD:if(m_ready)begin
                if(m_last)state<=IDLE;
                else begin iteration<=iteration+1'b1;state<=LAYER;end
            end
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
