// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module minimum_cycle_mean #(
    parameter integer NUM_NODES=8, WEIGHT_W=8, TAG_W=8
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [31:0] s_from,s_to,
    input wire signed [WEIGHT_W-1:0] s_weight,
    input wire s_present,s_keep,s_first,s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg m_has_cycle,
    output reg signed [WEIGHT_W+((NUM_NODES>1)?$clog2(NUM_NODES):0)+1:0] m_numerator,
    output reg [$clog2(NUM_NODES+1)-1:0] m_denominator,
    output reg [1:0] m_error,output reg [TAG_W-1:0] m_tag
);
    localparam integer N=NUM_NODES,W=WEIGHT_W;
    localparam integer IW=(N>1)?$clog2(N):1,CW=$clog2(N+1);
    localparam integer DW=W+((N>1)?$clog2(N):0)+1,NW=DW+1,PW=NW+CW;
    localparam integer AW=(N*N>1)?$clog2(N*N):1;
    localparam integer CLEAR=0,CAPTURE=1,DINIT=2,ROW=3,READ=4,ACC=5,STORE=6,
        VREAD=7,VBEGIN=8,KREAD=9,KLOAD=10,COMPARE=11,MUL=12,KNEXT=13,
        VNEXT=14,RESP=15,ERROR=16,HOLD=17;
    generate if(N<1 || N>32 || W<1 || W>16 || TAG_W<1 || TAG_W>32)begin:bad_parameters
        minimum_cycle_mean_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    reg [4:0] state;
    reg [W:0] adjacency[0:N*N-1];
    reg [DW:0] distance[0:(N+1)*N-1];
    reg [AW-1:0] cursor;
    reg [IW-1:0] dest,src,vertex,init_vertex;
    reg [CW-1:0] level,k;
    reg started;
    reg [1:0] errors;
    reg [TAG_W-1:0] tag;
    reg [W:0] edge_q;
    reg [DW:0] distance_q;
    reg accum_valid;
    reg signed [DW-1:0] accum_cost,final_cost;
    reg local_valid,global_valid,global_compare;
    reg signed [NW-1:0] candidate_num,local_num,global_num;
    reg [CW-1:0] candidate_den,local_den,global_den;
    reg signed [PW-1:0] mul_acc,mul_mcand,left_product;
    reg [CW-1:0] mul_factor,mul_step;
    reg mul_phase;
    wire [1:0] incoming_errors=errors |
        ((s_keep && (s_from>=N || s_to>=N))?2'b01:2'b00) |
        ((s_first!=!started)?2'b10:2'b00);
    wire signed [DW:0] relaxed=$signed({distance_q[DW-1],distance_q[DW-1:0]})+
        $signed({{(DW+1-W){edge_q[W-1]}},edge_q[W-1:0]});
    wire signed [NW-1:0] difference=$signed({final_cost[DW-1],final_cost})-
        $signed({distance_q[DW-1],distance_q[DW-1:0]});
    wire signed [NW-1:0] reference_num=global_compare?global_num:local_num;
    wire [CW-1:0] reference_den=global_compare?global_den:local_den;
    wire reference_valid=global_compare?global_valid:local_valid;
    wire signed [PW-1:0] mul_next=mul_acc+(mul_factor[0]?mul_mcand:{PW{1'b0}});
    wire improve=global_compare?($signed(left_product)<$signed(mul_next)):
        ($signed(left_product)>$signed(mul_next));
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==HOLD;
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;cursor<=0;started<=0;errors<=0;tag<=0;
            m_has_cycle<=0;m_numerator<=0;m_denominator<=0;m_error<=0;m_tag<=0;
        end else case(state)
            CLEAR:begin
                adjacency[cursor]<=0;
                if(cursor==N*N-1)begin cursor<=0;state<=CAPTURE;end
                else cursor<=cursor+1'b1;
            end
            CAPTURE:if(s_valid)begin
                if(!started)tag<=s_tag;
                started<=1;errors<=incoming_errors;
                if(s_keep && s_from<N && s_to<N)
                    adjacency[s_from*N+s_to]<={s_present,s_weight};
                if(s_last)begin
                    if(incoming_errors!=0)state<=ERROR;
                    else begin init_vertex<=0;state<=DINIT;end
                end
            end
            DINIT:begin
                // Implicit zero-cost super-source reaches every vertex.
                distance[init_vertex]<={1'b1,{DW{1'b0}}};
                global_valid<=0;global_num<=0;global_den<=0;vertex<=0;
                if(init_vertex==N-1)begin level<=1;dest<=0;state<=ROW;end
                else init_vertex<=init_vertex+1'b1;
            end
            ROW:begin accum_valid<=0;accum_cost<=0;src<=0;state<=READ;end
            READ:begin
                edge_q<=adjacency[src*N+dest];
                distance_q<=distance[(level-1)*N+src];state<=ACC;
            end
            ACC:begin
                if(edge_q[W] && distance_q[DW] &&
                    (!accum_valid || relaxed<$signed({accum_cost[DW-1],accum_cost})))begin
                    accum_valid<=1;accum_cost<=relaxed[DW-1:0];
                end
                if(src==N-1)state<=STORE;
                else begin src<=src+1'b1;state<=READ;end
            end
            STORE:begin
                distance[level*N+dest]<={accum_valid,accum_cost};
                if(dest==N-1)begin
                    dest<=0;
                    if(level==N)state<=VREAD;
                    else begin level<=level+1'b1;state<=ROW;end
                end else begin dest<=dest+1'b1;state<=ROW;end
            end
            VREAD:begin distance_q<=distance[N*N+vertex];state<=VBEGIN;end
            VBEGIN:begin
                final_cost<=distance_q[DW-1:0];local_valid<=0;local_num<=0;local_den<=0;
                if(distance_q[DW])begin k<=0;state<=KREAD;end else state<=VNEXT;
            end
            KREAD:begin distance_q<=distance[k*N+vertex];state<=KLOAD;end
            KLOAD:begin
                if(distance_q[DW])begin
                    candidate_num<=difference;candidate_den<=N-k;
                    global_compare<=0;state<=COMPARE;
                end else state<=KNEXT;
            end
            COMPARE:begin
                if(!reference_valid)begin
                    if(global_compare)begin
                        global_valid<=1;global_num<=candidate_num;global_den<=candidate_den;
                        state<=VNEXT;
                    end else begin
                        local_valid<=1;local_num<=candidate_num;local_den<=candidate_den;
                        state<=KNEXT;
                    end
                end else begin
                    // One signed multiplier is reused for both cross-products.
                    mul_mcand<={{(PW-NW){candidate_num[NW-1]}},candidate_num};
                    mul_factor<=reference_den;mul_acc<=0;mul_step<=0;mul_phase<=0;state<=MUL;
                end
            end
            MUL:begin
                if(mul_step==CW-1)begin
                    if(!mul_phase)begin
                        left_product<=mul_next;
                        mul_mcand<={{(PW-NW){reference_num[NW-1]}},reference_num};
                        mul_factor<=candidate_den;mul_acc<=0;mul_step<=0;mul_phase<=1;
                    end else begin
                        if(improve)begin
                            if(global_compare)begin global_num<=candidate_num;global_den<=candidate_den;end
                            else begin local_num<=candidate_num;local_den<=candidate_den;end
                        end
                        state<=global_compare?VNEXT:KNEXT;
                    end
                end else begin
                    mul_acc<=mul_next;mul_mcand<=mul_mcand<<<1;
                    mul_factor<=mul_factor>>1;mul_step<=mul_step+1'b1;
                end
            end
            KNEXT:begin
                if(k==N-1)begin
                    candidate_num<=local_num;candidate_den<=local_den;global_compare<=1;state<=COMPARE;
                end else begin k<=k+1'b1;state<=KREAD;end
            end
            VNEXT:begin
                if(vertex==N-1)state<=RESP;
                else begin vertex<=vertex+1'b1;state<=VREAD;end
            end
            RESP:begin
                m_has_cycle<=global_valid;m_numerator<=global_valid?global_num:0;
                m_denominator<=global_valid?global_den:0;m_error<=0;m_tag<=tag;state<=HOLD;
            end
            ERROR:begin
                m_has_cycle<=0;m_numerator<=0;m_denominator<=0;m_error<=errors;m_tag<=tag;state<=HOLD;
            end
            HOLD:if(m_ready)begin started<=0;errors<=0;cursor<=0;state<=CLEAR;end
            default:state<=CLEAR;
        endcase
    end
endmodule
