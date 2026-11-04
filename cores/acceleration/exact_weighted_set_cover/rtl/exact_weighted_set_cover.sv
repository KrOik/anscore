// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module exact_weighted_set_cover #(
    parameter integer NUM_SETS=8,UNIVERSE_W=16,WEIGHT_W=8,TAG_W=8,
    localparam integer DW=(NUM_SETS>0)?$clog2(NUM_SETS+1):1,
    localparam integer SUM_W=WEIGHT_W+((NUM_SETS>1)?$clog2(NUM_SETS):0)
)(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [UNIVERSE_W-1:0] c_target,
    input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,
    input wire [UNIVERSE_W-1:0] s_members,
    input wire [WEIGHT_W-1:0] s_weight,
    input wire s_last,
    output wire m_valid,input wire m_ready,
    output reg m_feasible,
    output reg [NUM_SETS-1:0] m_selection,
    output reg [SUM_W-1:0] m_weight,
    output reg [1:0] m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam integer ROW_W=UNIVERSE_W+WEIGHT_W;
    localparam integer FRAME_W=DW+UNIVERSE_W+SUM_W+NUM_SETS;
    localparam [2:0] IDLE=0,LOAD=1,EVAL=2,CHILD=3,POP=4,RESTORE=5,FINISH=6,OUT=7;
    reg [2:0] state;
    reg [ROW_W-1:0] rows[0:NUM_SETS-1];
    reg [FRAME_W-1:0] pending[0:NUM_SETS-1];
    // RAM data is never reset; ownership guarantees a current write before use.
    reg [ROW_W-1:0] row_q;
    reg [FRAME_W-1:0] frame_q;
    reg [DW-1:0] load_index,depth,sp;
    reg [UNIVERSE_W-1:0] target,covered;
    reg [SUM_W-1:0] cost,best_cost;
    reg [NUM_SETS-1:0] selected,best_selected;
    reg best_valid;
    wire complete=(covered & target)==target;
    wire terminal_node=complete || depth==NUM_SETS || (best_valid && cost>best_cost);
    wire [DW-1:0] next_depth=depth+1'b1;
    wire [NUM_SETS-1:0] include_bit={{(NUM_SETS-1){1'b0}},1'b1}<<depth;
    wire [SUM_W-1:0] row_cost={{(SUM_W-WEIGHT_W){1'b0}},row_q[WEIGHT_W-1:0]};
    assign c_ready=!rst && state==IDLE;
    assign s_ready=!rst && state==LOAD;
    assign m_valid=!rst && state==OUT;
    generate if(NUM_SETS<1 || NUM_SETS>16 || UNIVERSE_W<1 || UNIVERSE_W>32 ||
                WEIGHT_W<1 || WEIGHT_W>16 || TAG_W<1 || TAG_W>32)begin : g_invalid
        exact_weighted_set_cover_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    always @(posedge clk)begin
        if(!rst)begin
            if(state==LOAD && s_valid)rows[load_index]<={s_members,s_weight};
            if(state==EVAL && !terminal_node)row_q<=rows[depth];
            if(state==CHILD)pending[sp]<={next_depth,covered,cost,selected};
            if(state==POP && sp!=0)frame_q<=pending[sp-1'b1];
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;load_index<=0;depth<=0;sp<=0;target<=0;covered<=0;
            cost<=0;best_cost<=0;selected<=0;best_selected<=0;best_valid<=0;
            m_feasible<=0;m_selection<=0;m_weight<=0;m_error<=0;m_tag<=0;
        end else case(state)
            IDLE: if(c_valid)begin
                target<=c_target;m_tag<=c_tag;load_index<=0;depth<=0;sp<=0;
                covered<=0;cost<=0;selected<=0;best_cost<=0;best_selected<=0;
                best_valid<=0;m_error<=0;state<=LOAD;
            end
            LOAD: if(s_valid)begin
                if(s_last && load_index!=NUM_SETS-1)begin m_error<=1;state<=FINISH;end
                else if(load_index==NUM_SETS-1)begin
                    if(!s_last)begin m_error<=2;state<=FINISH;end
                    else state<=EVAL;
                end else load_index<=load_index+1'b1;
            end
            EVAL: begin
                if(complete)begin
                    if(!best_valid || cost<best_cost || (cost==best_cost && selected<best_selected))begin
                        best_valid<=1;best_cost<=cost;best_selected<=selected;
                    end
                    state<=POP;
                end else if(terminal_node)state<=POP;
                else state<=CHILD;
            end
            CHILD: begin
                sp<=sp+1'b1;depth<=next_depth;
                covered<=covered | row_q[WEIGHT_W+:UNIVERSE_W];
                cost<=cost+row_cost;selected<=selected | include_bit;state<=EVAL;
            end
            POP: begin
                if(sp==0)state<=FINISH;
                else begin sp<=sp-1'b1;state<=RESTORE;end
            end
            RESTORE: begin
                {depth,covered,cost,selected}<=frame_q;state<=EVAL;
            end
            FINISH: begin
                m_feasible<=m_error==0 && best_valid;
                m_weight<=(m_error==0 && best_valid)?best_cost:{SUM_W{1'b0}};
                m_selection<=(m_error==0 && best_valid)?best_selected:{NUM_SETS{1'b0}};
                state<=OUT;
            end
            OUT: if(m_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
