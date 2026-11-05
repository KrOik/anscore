// SPDX-License-Identifier: Apache-2.0
// Original bounded one-sided area-variation detector; no upstream code adopted.
`timescale 1ns/1ps
module grayscale_stable_extremal_regions #(
    parameter WIDTH=8, HEIGHT=8, CONNECTIVITY=4, TAG_W=8,
    localparam N=WIDTH*HEIGHT,
    localparam IW=(N<2)?1:$clog2(N), CW=(N<2)?1:$clog2(N+1),
    localparam XW=(WIDTH<2)?1:$clog2(WIDTH)
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [7:0] s_pixel,input wire s_sof,s_eol,
    input wire [TAG_W-1:0] s_tag,
    input wire cfg_bright,input wire [7:0] cfg_delta,cfg_variation_p,cfg_variation_q,
    input wire [CW-1:0] cfg_min_area,cfg_max_area,
    output wire m_valid,input wire m_ready,
    output wire [IW-1:0] m_index,
    output reg [IW-1:0] m_parent,
    output reg [7:0] m_level,
    output reg [CW-1:0] m_area,m_variation_num,m_variation_den,
    output reg m_canonical,m_selected,
    output wire m_sof,m_eol,m_last,
    output wire [2:0] m_errors,output wire [TAG_W-1:0] m_tag
);
    generate if(WIDTH<1 || WIDTH>16 || HEIGHT<1 || HEIGHT>16 ||
                (CONNECTIVITY!=4 && CONNECTIVITY!=8) || TAG_W<1 || TAG_W>32)begin:bad
        grayscale_stable_extremal_regions_invalid_parameter__see_README invalid();
    end endgenerate
    localparam DEPTH=(N<1 || N>256)?1:N;
    localparam PAR=8, AREA=PAR+IW, CAN=AREA+CW, NUM=CAN+1, SEL=NUM+CW, NW=SEL+1;
    localparam CAPTURE=0,COLLECT=1,V_READ=2,V_LATCH=3,T_READ=4,T_EVAL=5,V_WRITE=6,
        P_READ=7,P_LATCH=8,PP_READ=9,PP_LATCH=10,MUL=11,MUL_DONE=12,
        LOSE_READ=13,LOSE_WRITE=14,F_READ=15,F_LATCH=16,F_WRITE=17,
        O_READ=18,O_LATCH=19,HOLD=20;
    reg [4:0] state;
    reg [IW-1:0] capture_index,scan_index,walk,own_parent,loser,output_index;
    reg [XW-1:0] capture_x,output_x;
    reg bright;
    reg [7:0] delta,variation_p,variation_q,own_level;
    reg [CW-1:0] min_area,max_area,own_area,own_num,parent_area,parent_num,top_area;
    reg own_canonical,selected_choice;
    reg [2:0] errors;
    reg [TAG_W-1:0] tag;
    reg [NW-1:0] nodes[0:DEPTH-1],node_q,own_word;
    reg [17:0] mul_shift,mul_acc,first_product;
    reg [8:0] mul_factor;
    reg [3:0] mul_step;
    reg [1:0] mul_purpose;
    wire [7:0] q_level=node_q[7:0];
    wire [IW-1:0] q_parent=node_q[PAR+:IW];
    wire [CW-1:0] q_area=node_q[AREA+:CW],q_num=node_q[NUM+:CW];
    wire q_canonical=node_q[CAN],q_selected=node_q[SEL];
    wire configuration_bad=(cfg_delta==0 || cfg_variation_q==0 || cfg_min_area==0 ||
        cfg_min_area>cfg_max_area || cfg_max_area>N);
    wire [1:0] marker_bad={s_eol!=(capture_x==WIDTH-1),s_sof!=(capture_index==0)};
    wire tree_ready,tree_valid,tree_canonical,tree_sof,tree_eol,tree_last;
    wire [IW-1:0] tree_index,tree_parent;
    wire [7:0] tree_level;
    wire [CW-1:0] tree_area;
    wire [1:0] tree_errors;
    wire [TAG_W-1:0] tree_tag;
    wire tree_sink=!rst && state==COLLECT;
    // On invalid first configuration, deliberately invalidate only the child's
    // first SOF. Its existing drain/zero path avoids all tree arithmetic. Public
    // errors are derived independently from the caller's real marker/config pins.
    wire tree_input_sof=(capture_index==0 && configuration_bad)?1'b0:s_sof;
    wire effective_bright=(capture_index==0)?cfg_bright:bright;
    generate if(WIDTH>=1 && WIDTH<=16 && HEIGHT>=1 && HEIGHT<=16 &&
        (CONNECTIVITY==4 || CONNECTIVITY==8) && TAG_W>=1 && TAG_W<=32)begin:dependency
    grayscale_max_tree #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.PIXEL_W(8),
        .CONNECTIVITY(CONNECTIVITY),.TAG_W(TAG_W)) tree(
        .clk(clk),.rst(rst),.s_valid(!rst && state==CAPTURE && s_valid),.s_ready(tree_ready),
        .s_pixel(effective_bright?s_pixel:~s_pixel),.s_sof(tree_input_sof),.s_eol(s_eol),.s_tag(s_tag),
        .m_valid(tree_valid),.m_ready(tree_sink),.m_index(tree_index),.m_parent(tree_parent),
        .m_level(tree_level),.m_canonical(tree_canonical),.m_area(tree_area),
        .m_sof(tree_sof),.m_eol(tree_eol),.m_last(tree_last),.m_errors(tree_errors),.m_tag(tree_tag)
    );
    end else begin:unused_dependency
        assign tree_ready=0;assign tree_valid=0;assign tree_index=0;assign tree_parent=0;
        assign tree_level=0;assign tree_canonical=0;assign tree_area=0;assign tree_sof=0;
        assign tree_eol=0;assign tree_last=0;assign tree_errors=0;assign tree_tag=0;
    end endgenerate
    assign s_ready=!rst && state==CAPTURE && tree_ready;
    assign m_valid=!rst && state==HOLD;
    assign m_index=output_index;
    assign m_sof=m_valid && output_index==0;
    assign m_eol=m_valid && output_x==WIDTH-1;
    assign m_last=m_valid && output_index==N-1;
    assign m_errors=errors;
    assign m_tag=tag;
    function [NW-1:0] pack_node;
        input [7:0] level_value;input [IW-1:0] parent_value;
        input [CW-1:0] area_value;input canonical_value;
        input [CW-1:0] numerator_value;input selected_value;
        begin pack_node={selected_value,numerator_value,canonical_value,area_value,parent_value,level_value};end
    endfunction
    // One clocked-read single-port node bank. Every read and write phase is
    // disjoint. The bank and read register have no reset and no collision mode.
    always @(posedge clk)if(!rst)begin
        case(state)
            COLLECT:if(tree_valid)nodes[tree_index]<=pack_node(tree_level,tree_parent,tree_area,
                tree_canonical,{CW{1'b0}},tree_canonical);
            V_READ,P_READ,F_READ:node_q<=nodes[scan_index];
            T_READ:node_q<=nodes[walk];
            V_WRITE:nodes[scan_index]<=pack_node(own_level,own_parent,own_area,own_canonical,
                own_canonical?(top_area-own_area):{CW{1'b0}},own_canonical);
            PP_READ:node_q<=nodes[own_parent];
            LOSE_READ:node_q<=nodes[loser];
            LOSE_WRITE:nodes[loser]<={1'b0,node_q[NW-2:0]};
            F_WRITE:nodes[scan_index]<={selected_choice,own_word[NW-2:0]};
            O_READ:node_q<=nodes[output_index];
        endcase
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;capture_index<=0;scan_index<=0;walk<=0;own_parent<=0;loser<=0;
            output_index<=0;capture_x<=0;output_x<=0;bright<=0;delta<=0;variation_p<=0;variation_q<=0;
            own_level<=0;min_area<=0;max_area<=0;own_area<=0;own_num<=0;parent_area<=0;parent_num<=0;
            top_area<=0;own_canonical<=0;selected_choice<=0;errors<=0;tag<=0;own_word<=0;
            mul_shift<=0;mul_acc<=0;first_product<=0;mul_factor<=0;mul_step<=0;mul_purpose<=0;
            m_parent<=0;m_level<=0;m_area<=0;m_variation_num<=0;m_variation_den<=0;
            m_canonical<=0;m_selected<=0;
        end else case(state)
            CAPTURE:if(s_valid && tree_ready)begin
                if(capture_index==0)begin
                    bright<=cfg_bright;delta<=cfg_delta;variation_p<=cfg_variation_p;variation_q<=cfg_variation_q;
                    min_area<=cfg_min_area;max_area<=cfg_max_area;tag<=s_tag;
                    errors<={configuration_bad,marker_bad};
                end else errors<=errors|{1'b0,marker_bad};
                if(capture_index==N-1)state<=COLLECT;
                else begin capture_index<=capture_index+1'b1;
                    if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1'b1;end
            end
            COLLECT:if(tree_valid && tree_last)begin
                scan_index<=0;
                if(errors!=0)begin
                    output_index<=0;output_x<=0;m_parent<=0;m_level<=0;m_area<=0;
                    m_variation_num<=0;m_variation_den<=0;m_canonical<=0;m_selected<=0;state<=HOLD;
                end else state<=V_READ;
            end
            V_READ:state<=V_LATCH;
            V_LATCH:begin
                own_level<=q_level;own_parent<=q_parent;own_area<=q_area;top_area<=q_area;
                own_canonical<=q_canonical;
                if(!q_canonical || q_parent==scan_index)state<=V_WRITE;
                else begin walk<=q_parent;state<=T_READ;end
            end
            T_READ:state<=T_EVAL;
            T_EVAL:begin
                // Strictly decreasing g along canonical parents makes this
                // unsigned9 subtraction nonnegative over all owned pointers.
                if(({1'b0,own_level}-{1'b0,q_level})<={1'b0,delta})begin
                    top_area<=q_area;
                    if(q_parent==walk)state<=V_WRITE;else begin walk<=q_parent;state<=T_READ;end
                end else state<=V_WRITE;
            end
            V_WRITE:if(scan_index==N-1)begin scan_index<=0;state<=P_READ;end
                else begin scan_index<=scan_index+1'b1;state<=V_READ;end
            P_READ:state<=P_LATCH;
            P_LATCH:begin
                own_level<=q_level;own_parent<=q_parent;own_area<=q_area;own_num<=q_num;
                if(q_canonical && q_parent!=scan_index)state<=PP_READ;
                else if(scan_index==N-1)begin scan_index<=0;state<=F_READ;end
                else begin scan_index<=scan_index+1'b1;state<=P_READ;end
            end
            PP_READ:state<=PP_LATCH;
            PP_LATCH:begin
                parent_area<=q_area;parent_num<=q_num;
                if(({1'b0,own_level}-{1'b0,q_level})==9'd1)begin
                    mul_shift<={{(18-CW){1'b0}},own_num};mul_factor<={{(9-CW){1'b0}},q_area};
                    mul_acc<=0;mul_step<=0;mul_purpose<=0;state<=MUL;
                end else if(scan_index==N-1)begin scan_index<=0;state<=F_READ;end
                else begin scan_index<=scan_index+1'b1;state<=P_READ;end
            end
            MUL:begin
                if(mul_factor[0])mul_acc<=mul_acc+mul_shift;
                mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
                if(mul_step==8)state<=MUL_DONE;else mul_step<=mul_step+1'b1;
            end
            MUL_DONE:case(mul_purpose)
                0:begin
                    first_product<=mul_acc;mul_shift<={{(18-CW){1'b0}},parent_num};
                    mul_factor<={{(9-CW){1'b0}},own_area};mul_acc<=0;mul_step<=0;mul_purpose<=1;state<=MUL;
                end
                1:begin loser<=(first_product<mul_acc)?own_parent:scan_index;state<=LOSE_READ;end
                2:begin
                    first_product<=mul_acc;mul_shift<={10'b0,variation_p};
                    mul_factor<={{(9-CW){1'b0}},own_area};mul_acc<=0;mul_step<=0;mul_purpose<=3;state<=MUL;
                end
                3:begin selected_choice<=first_product<mul_acc;state<=F_WRITE;end
            endcase
            LOSE_READ:state<=LOSE_WRITE;
            LOSE_WRITE:if(scan_index==N-1)begin scan_index<=0;state<=F_READ;end
                else begin scan_index<=scan_index+1'b1;state<=P_READ;end
            F_READ:state<=F_LATCH;
            F_LATCH:begin
                own_word<=node_q;own_area<=q_area;
                if(q_canonical && q_selected && q_parent!=scan_index && q_area>=min_area && q_area<=max_area)begin
                    mul_shift<={{(18-CW){1'b0}},q_num};mul_factor<={1'b0,variation_q};
                    mul_acc<=0;mul_step<=0;mul_purpose<=2;state<=MUL;
                end else begin selected_choice<=0;state<=F_WRITE;end
            end
            F_WRITE:if(scan_index==N-1)begin output_index<=0;output_x<=0;state<=O_READ;end
                else begin scan_index<=scan_index+1'b1;state<=F_READ;end
            O_READ:state<=O_LATCH;
            O_LATCH:begin
                m_canonical<=q_canonical;m_selected<=q_selected;
                m_parent<=q_canonical?q_parent:{IW{1'b0}};
                m_level<=q_canonical?(bright?q_level:~q_level):8'b0;
                m_area<=q_canonical?q_area:{CW{1'b0}};
                m_variation_num<=q_canonical?q_num:{CW{1'b0}};
                m_variation_den<=q_canonical?q_area:{CW{1'b0}};state<=HOLD;
            end
            HOLD:if(m_ready)begin
                if(output_index==N-1)begin capture_index<=0;capture_x<=0;state<=CAPTURE;end
                else begin output_index<=output_index+1'b1;
                    if(output_x==WIDTH-1)output_x<=0;else output_x<=output_x+1'b1;
                    if(errors==0)state<=O_READ;end
            end
            default:begin state<=CAPTURE;capture_index<=0;capture_x<=0;end
        endcase
    end
endmodule
