// Original exact bounded point-set minimum-area rectangle datapath.
module minimum_area_rectangle #(
    parameter COORD_W=8, MAX_POINTS=8, TAG_W=8,
    localparam IW=(MAX_POINTS<2)?1:$clog2(MAX_POINTS),
    localparam CW=(MAX_POINTS<2)?1:$clog2(MAX_POINTS+1),
    localparam MW=4*COORD_W+4, RW=2*MW,
    localparam BW=(MW<2)?1:$clog2(MW)
)(
    input wire clk,rst,
    input wire s_valid, output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,
    input wire s_keep,s_last, input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg signed [MW-1:0] m_axis_x,m_axis_y,
    output reg signed [MW-1:0] m_u_min,m_u_max,m_v_min,m_v_max,
    output reg [MW-1:0] m_den,m_area_num,
    output reg m_pair_valid,
    output reg [IW-1:0] m_pair_i,m_pair_j,
    output reg [IW-1:0] m_u_min_index,m_u_max_index,m_v_min_index,m_v_max_index,
    output wire [1:0] m_dimension,
    output reg [1:0] m_status,
    output wire [CW-1:0] m_count, output wire [TAG_W-1:0] m_tag
);
    generate if(COORD_W<2 || COORD_W>12 || MAX_POINTS<1 || MAX_POINTS>8 || TAG_W<1 || TAG_W>32)begin:bad
        minimum_area_rectangle_invalid_parameter__see_README invalid();
    end endgenerate
    localparam CAPTURE=0,INIT_READ=1,INIT_LATCH=2,A_READ=3,A_LATCH=4,
        B_READ=5,DIFF=6,P_READ=7,P_LATCH=8,MSTART=9,MRUN=10,MDONE=11,
        EVAL=12,NEXT=13,OUTPUT=14;
    reg [3:0] state,op;
    reg active,overflow;
    reg [CW-1:0] count;
    reg [TAG_W-1:0] tag;
    reg [IW-1:0] i,j,k,umin_idx,umax_idx,vmin_idx,vmax_idx;
    reg [2*COORD_W-1:0] points[0:MAX_POINTS-1];
    reg [2*COORD_W-1:0] ram_q;
    reg signed [COORD_W-1:0] ax,ay;
    reg signed [MW-1:0] dx,dy,px,py,tmp,u_value;
    reg signed [MW-1:0] min_u,max_u,min_v,max_v;
    reg [MW-1:0] cand_den,cand_area;
    reg [RW-1:0] mul_shift,mul_acc,mul_result,compare_saved;
    reg [MW-1:0] mul_bits;
    reg [BW-1:0] mul_step;
    reg mul_sign;
    reg signed [MW-1:0] operand_a,operand_b;
    wire signed [COORD_W-1:0] qx=ram_q[2*COORD_W-1:COORD_W];
    wire signed [COORD_W-1:0] qy=ram_q[COORD_W-1:0];
    wire signed [COORD_W:0] delta_x=$signed({qx[COORD_W-1],qx})-$signed({ax[COORD_W-1],ax});
    wire signed [COORD_W:0] delta_y=$signed({qy[COORD_W-1],qy})-$signed({ay[COORD_W-1],ay});
    wire signed [MW-1:0] delta_x_wide={{(MW-COORD_W-1){delta_x[COORD_W]}},delta_x};
    wire signed [MW-1:0] delta_y_wide={{(MW-COORD_W-1){delta_y[COORD_W]}},delta_y};
    wire signed [MW-1:0] product_low=$signed(mul_result[MW-1:0]);
    wire signed [MW-1:0] v_value=tmp-product_low;
    wire [RW-1:0] mul_next=mul_acc+(mul_bits[0]?mul_shift:{RW{1'b0}});
    wire [MW-1:0] magnitude_a=operand_a[MW-1]?-operand_a:operand_a;
    wire [MW-1:0] magnitude_b=operand_b[MW-1]?-operand_b:operand_b;
    wire [IW-1:0] read_address=(state==INIT_READ)?{IW{1'b0}}:(state==A_READ)?i:(state==B_READ)?j:k;
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUTPUT;
    assign m_count=count;
    assign m_tag=tag;
    assign m_dimension=(m_status!=0)?2'd0:(m_area_num!=0)?2'd2:m_pair_valid?2'd1:2'd0;
    always @* begin
        operand_a=0;operand_b=0;
        case(op)
            0:begin operand_a=dx;operand_b=dx;end
            1:begin operand_a=dy;operand_b=dy;end
            2:begin operand_a=px;operand_b=dx;end
            3:begin operand_a=py;operand_b=dy;end
            4:begin operand_a=py;operand_b=dx;end
            5:begin operand_a=px;operand_b=dy;end
            6:begin operand_a=max_u-min_u;operand_b=max_v-min_v;end
            7:begin operand_a=cand_area;operand_b=m_den;end
            8:begin operand_a=m_area_num;operand_b=cand_den;end
            default:begin operand_a=0;operand_b=0;end
        endcase
    end
    // Capture and registered reads are disjoint. Only the newly owned prefix is read.
    always @(posedge clk) if(!rst)begin
        if(state==CAPTURE && s_valid && s_keep && count<MAX_POINTS)points[count[IW-1:0]]<={s_x,s_y};
        if(state==INIT_READ || state==A_READ || state==B_READ || state==P_READ)ram_q<=points[read_address];
    end
    task clear_geometry;
        begin
            m_axis_x<=0;m_axis_y<=0;m_u_min<=0;m_u_max<=0;m_v_min<=0;m_v_max<=0;
            m_den<=0;m_area_num<=0;m_pair_valid<=0;m_pair_i<=0;m_pair_j<=0;
            m_u_min_index<=0;m_u_max_index<=0;m_v_min_index<=0;m_v_max_index<=0;
        end
    endtask
    task save_candidate;
        begin
            m_axis_x<=dx;m_axis_y<=dy;m_u_min<=min_u;m_u_max<=max_u;m_v_min<=min_v;m_v_max<=max_v;
            m_den<=cand_den;m_area_num<=cand_area;m_pair_valid<=1;m_pair_i<=i;m_pair_j<=j;
            m_u_min_index<=umin_idx;m_u_max_index<=umax_idx;m_v_min_index<=vmin_idx;m_v_max_index<=vmax_idx;
        end
    endtask
    always @(posedge clk) begin
        if(rst)begin
            state<=CAPTURE;active<=0;overflow<=0;count<=0;tag<=0;m_status<=0;clear_geometry();
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(!active)begin active<=1;tag<=s_tag;clear_geometry();m_status<=0;end
                if(s_keep)begin if(count<MAX_POINTS)count<=count+1'b1;else overflow<=1;end
                if(s_last)begin
                    if(overflow || (s_keep && count==MAX_POINTS))begin m_status<=2;clear_geometry();state<=OUTPUT;end
                    else if(count==0 && !s_keep)begin m_status<=1;clear_geometry();state<=OUTPUT;end
                    else state<=INIT_READ;
                end
            end
            INIT_READ:state<=INIT_LATCH;
            INIT_LATCH:begin
                m_axis_x<=1;m_axis_y<=0;m_den<=1;m_area_num<=0;
                m_u_min<=qx;m_u_max<=qx;m_v_min<=qy;m_v_max<=qy;
                if(count==1)state<=OUTPUT;
                else begin i<=0;j<=1;state<=A_READ;end
            end
            A_READ:state<=A_LATCH;
            A_LATCH:begin ax<=qx;ay<=qy;state<=B_READ;end
            B_READ:state<=DIFF;
            DIFF:begin
                if(delta_x==0 && delta_y==0)state<=NEXT;
                else begin
                    if(delta_x<0 || (delta_x==0 && delta_y<0))begin dx<=-delta_x_wide;dy<=-delta_y_wide;end
                    else begin dx<=delta_x_wide;dy<=delta_y_wide;end
                    op<=0;state<=MSTART;
                end
            end
            P_READ:state<=P_LATCH;
            P_LATCH:begin px<=qx;py<=qy;op<=2;state<=MSTART;end
            MSTART:begin
                mul_shift<={{MW{1'b0}},magnitude_a};mul_bits<=magnitude_b;mul_acc<=0;
                mul_sign<=operand_a[MW-1]^operand_b[MW-1];mul_step<=0;state<=MRUN;
            end
            MRUN:begin
                mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_bits<=mul_bits>>1;
                if(mul_step==MW-1)begin mul_result<=mul_sign?-mul_next:mul_next;state<=MDONE;end
                else mul_step<=mul_step+1'b1;
            end
            MDONE:case(op)
                0:begin tmp<=product_low;op<=1;state<=MSTART;end
                1:begin cand_den<=tmp+product_low;k<=0;state<=P_READ;end
                2:begin tmp<=product_low;op<=3;state<=MSTART;end
                3:begin u_value<=tmp+product_low;op<=4;state<=MSTART;end
                4:begin tmp<=product_low;op<=5;state<=MSTART;end
                5:begin
                    if(k==0)begin
                        min_u<=u_value;max_u<=u_value;min_v<=v_value;max_v<=v_value;
                        umin_idx<=0;umax_idx<=0;vmin_idx<=0;vmax_idx<=0;
                    end else begin
                        if(u_value<min_u)begin min_u<=u_value;umin_idx<=k;end
                        if(u_value>max_u)begin max_u<=u_value;umax_idx<=k;end
                        if(v_value<min_v)begin min_v<=v_value;vmin_idx<=k;end
                        if(v_value>max_v)begin max_v<=v_value;vmax_idx<=k;end
                    end
                    if({1'b0,k}+1'b1<count)begin k<=k+1'b1;state<=P_READ;end
                    else state<=EVAL;
                end
                6:begin
                    cand_area<=product_low;
                    // First direction needs no comparison; all following ties retain it.
                    if(!m_pair_valid)begin
                        m_axis_x<=dx;m_axis_y<=dy;m_u_min<=min_u;m_u_max<=max_u;m_v_min<=min_v;m_v_max<=max_v;
                        m_den<=cand_den;m_area_num<=product_low;m_pair_valid<=1;m_pair_i<=i;m_pair_j<=j;
                        m_u_min_index<=umin_idx;m_u_max_index<=umax_idx;m_v_min_index<=vmin_idx;m_v_max_index<=vmax_idx;
                        state<=NEXT;
                    end else begin op<=7;state<=MSTART;end
                end
                7:begin compare_saved<=mul_result;op<=8;state<=MSTART;end
                8:begin if(compare_saved<mul_result)save_candidate();state<=NEXT;end
                default:state<=NEXT;
            endcase
            EVAL:begin op<=6;state<=MSTART;end
            NEXT:begin
                if({1'b0,j}+1'b1<count)begin j<=j+1'b1;state<=A_READ;end
                else if({1'b0,i}+2'd2<count)begin i<=i+1'b1;j<=i+2'd2;state<=A_READ;end
                else state<=OUTPUT;
            end
            OUTPUT:if(m_ready)begin state<=CAPTURE;active<=0;overflow<=0;count<=0;end
            default:state<=CAPTURE;
        endcase
    end
endmodule
