// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module point_delaunay #(
    parameter integer COORD_W=8, MAX_POINTS=8, TAG_W=8,
    localparam integer IW=(MAX_POINTS<2)?1:$clog2(MAX_POINTS),
    localparam integer CW=(MAX_POINTS<2)?1:$clog2(MAX_POINTS+1),
    localparam integer TM=(2*MAX_POINTS-5<1)?1:2*MAX_POINTS-5,
    localparam integer TCW=(TM<2)?1:$clog2(TM+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [COORD_W-1:0] s_x,s_y,
    input wire s_keep,s_last,s_error,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [IW-1:0] m_id0,m_id1,m_id2,
    output wire signed [COORD_W-1:0] m_x0,m_y0,m_x1,m_y1,m_x2,m_y2,
    output wire [CW-1:0] m_points,m_unique,
    output wire [TCW-1:0] m_count,m_index,
    output wire [2:0] m_error,output wire [1:0] m_dimension,
    output wire m_has_triangle,m_first,m_last,output wire [TAG_W-1:0] m_tag
);
    generate if(COORD_W<2 || COORD_W>12 || MAX_POINTS<1 || MAX_POINTS>16 || TAG_W<1 || TAG_W>32) begin:g_invalid
        point_delaunay_invalid_parameters__see_README invalid_parameters();
    end endgenerate
    localparam integer DW=COORD_W+1,PW=2*COORD_W+2,LW=2*COORD_W+1,
                       XW=2*COORD_W+3,AW=2*COORD_W+3,BW=2*COORD_W+2,
                       MW=4*COORD_W+5,SW=4*COORD_W+7;
    localparam [4:0] CAPTURE=0,CHECK=1,DUP_I=2,DUP_J=3,DUP_EVAL=4,
        TRI_START=5,TRI_B=6,TRI_C=7,TRI_ADV=8,ORI_SETUP=9,ORI_EVAL=10,
        QUERY_NEXT=11,QUERY_SETUP=12,QUERY_EVAL=13,TRI_STORE=14,FINALIZE=15,
        OUT_READ=16,OUT_LOAD=17,OUT_B=18,OUT_C=19,OUT_READY=20,OUT_HOLD=21,
        ZERO_PREP=22,LOAD_READ=23,LOAD_LATCH=24,MUL_RUN=25,MUL_RET=26;

    reg signed [COORD_W-1:0] x_mem[0:MAX_POINTS-1],y_mem[0:MAX_POINTS-1];
    reg [3*IW-1:0] triangle_mem[0:TM-1];
    reg [4:0] state,load_return;
    reg [1:0] load_slot;
    reg [IW-1:0] load_id;
    reg signed [COORD_W-1:0] ax,ay,bx,by,cx,cy,px,py,x_q,y_q;
    reg [3*IW-1:0] triangle_q;
    reg signed [DW-1:0] dx0,dy0,dx1,dy1,dx2,dy2;
    reg signed [MW-1:0] product_q;
    reg signed [PW-1:0] small_product;
    reg [LW-1:0] lift;
    reg signed [XW-1:0] cross_q;
    reg signed [SW-1:0] incircle_q;
    reg signed [1:0] orientation_sign,bc_sign;
    reg math_mode;
    reg [3:0] math_job;
    reg [IW-1:0] i,j,k,p,out_id0,out_id1,out_id2;
    reg [CW-1:0] point_count,unique_count;
    reg [TCW-1:0] triangle_count,out_index;
    reg [TAG_W-1:0] tag;
    reg [2:0] errors;
    reg seen;
    reg [MAX_POINTS-1:0] live;

    reg signed [AW-1:0] mul_a;
    reg signed [BW-1:0] mul_b;
    always @* begin
        mul_a=0;mul_b=0;
        if(!math_mode) begin
            if(math_job==0)begin mul_a=dx0;mul_b=dy1;end
            else begin mul_a=dy0;mul_b=dx1;end
        end else case(math_job)
            0:begin mul_a=dx0;mul_b=dx0;end
            1:begin mul_a=dy0;mul_b=dy0;end
            2:begin mul_a=dx1;mul_b=dy2;end
            3:begin mul_a=dy1;mul_b=dx2;end
            5:begin mul_a=dx1;mul_b=dx1;end
            6:begin mul_a=dy1;mul_b=dy1;end
            7:begin mul_a=dx2;mul_b=dy0;end
            8:begin mul_a=dy2;mul_b=dx0;end
            10:begin mul_a=dx2;mul_b=dx2;end
            11:begin mul_a=dy2;mul_b=dy2;end
            12:begin mul_a=dx0;mul_b=dy1;end
            13:begin mul_a=dy0;mul_b=dx1;end
            4,9,14:begin mul_a=cross_q;mul_b=$signed({1'b0,lift});end
            default:begin mul_a=0;mul_b=0;end
        endcase
    end
    wire signed [XW-1:0] difference_product=
        $signed({small_product[PW-1],small_product})-
        $signed({product_q[PW-1],product_q[PW-1:0]});
    wire signed [SW-1:0] extended_product={{(SW-MW){product_q[MW-1]}},product_q};
    wire reject_circle=(incircle_q!=0)?((incircle_q>0)==(orientation_sign>0)):
                       ((p<i)||((bc_sign>0)!=(orientation_sign>0)));

    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_first=m_valid && out_index==0;
    assign m_last=m_valid && (triangle_count==0 || out_index+1'b1==triangle_count);
    assign m_has_triangle=m_valid && errors==0 && triangle_count!=0;
    assign m_dimension=(errors!=0 || unique_count<2)?0:((triangle_count==0)?1:2);
    assign m_id0=out_id0;assign m_id1=out_id1;assign m_id2=out_id2;
    assign m_x0=ax;assign m_y0=ay;assign m_x1=bx;assign m_y1=by;assign m_x2=cx;assign m_y2=cy;
    assign m_points=point_count;assign m_unique=unique_count;
    assign m_count=triangle_count;assign m_index=out_index;assign m_error=errors;assign m_tag=tag;

    always @(posedge clk) begin
        if(rst)begin
            state<=CAPTURE;point_count<=0;unique_count<=0;triangle_count<=0;
            out_index<=0;tag<=0;errors<=0;seen<=0;
            ax<=0;ay<=0;bx<=0;by<=0;cx<=0;cy<=0;
            out_id0<=0;out_id1<=0;out_id2<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(!seen)begin tag<=s_tag;seen<=1;end
                if(s_error)errors[1]<=1;
                if(s_keep)begin
                    if(point_count<MAX_POINTS)begin
                        x_mem[point_count]<=s_x;y_mem[point_count]<=s_y;
                        live[point_count]<=1;point_count<=point_count+1'b1;
                    end else errors[0]<=1;
                end
                if(s_last)state<=CHECK;
            end
            CHECK:begin
                unique_count<=point_count;triangle_count<=0;out_index<=0;
                i<=0;j<=1;k<=2;p<=0;
                if(errors!=0)begin unique_count<=0;state<=ZERO_PREP;end
                else if(point_count<2)state<=FINALIZE;
                else state<=DUP_I;
            end
            DUP_I:begin
                if(i+1>=point_count)begin
                    i<=0;j<=1;k<=2;
                    if(unique_count<3)state<=FINALIZE;else state<=TRI_START;
                end else if(!live[i])i<=i+1'b1;
                else begin
                    j<=i+1'b1;load_id<=i;load_slot<=0;load_return<=DUP_J;state<=LOAD_READ;
                end
            end
            DUP_J:begin
                if(!live[j])begin
                    if(j+1>=point_count)begin i<=i+1'b1;state<=DUP_I;end
                    else j<=j+1'b1;
                end else begin load_id<=j;load_slot<=3;load_return<=DUP_EVAL;state<=LOAD_READ;end
            end
            DUP_EVAL:begin
                if(ax==px && ay==py)begin live[j]<=0;unique_count<=unique_count-1'b1;end
                if(j+1>=point_count)begin i<=i+1'b1;state<=DUP_I;end
                else begin j<=j+1'b1;state<=DUP_J;end
            end
            TRI_START:begin
                if(!live[i] || !live[j] || !live[k])state<=TRI_ADV;
                else begin load_id<=i;load_slot<=0;load_return<=TRI_B;state<=LOAD_READ;end
            end
            TRI_B:begin load_id<=j;load_slot<=1;load_return<=TRI_C;state<=LOAD_READ;end
            TRI_C:begin load_id<=k;load_slot<=2;load_return<=ORI_SETUP;state<=LOAD_READ;end
            ORI_SETUP:begin
                dx0<=$signed({bx[COORD_W-1],bx})-$signed({ax[COORD_W-1],ax});
                dy0<=$signed({by[COORD_W-1],by})-$signed({ay[COORD_W-1],ay});
                dx1<=$signed({cx[COORD_W-1],cx})-$signed({ax[COORD_W-1],ax});
                dy1<=$signed({cy[COORD_W-1],cy})-$signed({ay[COORD_W-1],ay});
                math_mode<=0;math_job<=0;state<=MUL_RUN;
            end
            ORI_EVAL:begin
                if(orientation_sign==0)state<=TRI_ADV;
                else begin p<=0;state<=QUERY_NEXT;end
            end
            QUERY_NEXT:begin
                if(!live[p] || p==i || p==j || p==k)begin
                    if(p+1>=point_count)state<=TRI_STORE;else p<=p+1'b1;
                end else begin load_id<=p;load_slot<=3;load_return<=QUERY_SETUP;state<=LOAD_READ;end
            end
            QUERY_SETUP:begin
                dx0<=$signed({ax[COORD_W-1],ax})-$signed({px[COORD_W-1],px});
                dy0<=$signed({ay[COORD_W-1],ay})-$signed({py[COORD_W-1],py});
                dx1<=$signed({bx[COORD_W-1],bx})-$signed({px[COORD_W-1],px});
                dy1<=$signed({by[COORD_W-1],by})-$signed({py[COORD_W-1],py});
                dx2<=$signed({cx[COORD_W-1],cx})-$signed({px[COORD_W-1],px});
                dy2<=$signed({cy[COORD_W-1],cy})-$signed({py[COORD_W-1],py});
                math_mode<=1;math_job<=0;incircle_q<=0;bc_sign<=0;state<=MUL_RUN;
            end
            QUERY_EVAL:begin
                if(reject_circle)state<=TRI_ADV;
                else if(p+1>=point_count)state<=TRI_STORE;
                else begin p<=p+1'b1;state<=QUERY_NEXT;end
            end
            TRI_STORE:begin
                if(triangle_count<TM)begin
                    triangle_mem[triangle_count]<=(orientation_sign>0)?{i,j,k}:{i,k,j};
                    triangle_count<=triangle_count+1'b1;state<=TRI_ADV;
                end else begin errors[2]<=1;triangle_count<=0;unique_count<=0;state<=ZERO_PREP;end
            end
            TRI_ADV:begin
                if(k+1<point_count)begin k<=k+1'b1;state<=TRI_START;end
                else if(j+2<point_count)begin j<=j+1'b1;k<=j+2;state<=TRI_START;end
                else if(i+3<point_count)begin i<=i+1'b1;j<=i+2;k<=i+3;state<=TRI_START;end
                else state<=FINALIZE;
            end
            FINALIZE:begin out_index<=0;if(triangle_count==0)state<=ZERO_PREP;else state<=OUT_READ;end
            OUT_READ:begin triangle_q<=triangle_mem[out_index];state<=OUT_LOAD;end
            OUT_LOAD:begin
                out_id0<=triangle_q[3*IW-1:2*IW];out_id1<=triangle_q[2*IW-1:IW];out_id2<=triangle_q[IW-1:0];
                load_id<=triangle_q[3*IW-1:2*IW];load_slot<=0;load_return<=OUT_B;state<=LOAD_READ;
            end
            OUT_B:begin load_id<=out_id1;load_slot<=1;load_return<=OUT_C;state<=LOAD_READ;end
            OUT_C:begin load_id<=out_id2;load_slot<=2;load_return<=OUT_READY;state<=LOAD_READ;end
            OUT_READY:state<=OUT_HOLD;
            ZERO_PREP:begin
                ax<=0;ay<=0;bx<=0;by<=0;cx<=0;cy<=0;out_id0<=0;out_id1<=0;out_id2<=0;
                out_index<=0;state<=OUT_HOLD;
            end
            OUT_HOLD:if(m_ready)begin
                if(triangle_count==0 || out_index+1'b1==triangle_count)begin
                    state<=CAPTURE;point_count<=0;unique_count<=0;triangle_count<=0;out_index<=0;errors<=0;seen<=0;
                end else begin out_index<=out_index+1'b1;state<=OUT_READ;end
            end
            LOAD_READ:begin x_q<=x_mem[load_id];y_q<=y_mem[load_id];state<=LOAD_LATCH;end
            LOAD_LATCH:begin
                case(load_slot)
                    0:begin ax<=x_q;ay<=y_q;end
                    1:begin bx<=x_q;by<=y_q;end
                    2:begin cx<=x_q;cy<=y_q;end
                    3:begin px<=x_q;py<=y_q;end
                endcase
                state<=load_return;
            end
            MUL_RUN:begin product_q<=mul_a*mul_b;state<=MUL_RET;end
            MUL_RET:begin
                if(!math_mode)begin
                    if(math_job==0)begin small_product<=product_q[PW-1:0];math_job<=1;state<=MUL_RUN;end
                    else begin
                        cross_q<=difference_product;
                        orientation_sign<=(difference_product>0)?2'sd1:((difference_product<0)?-2'sd1:2'sd0);
                        state<=ORI_EVAL;
                    end
                end else begin
                    case(math_job)
                        0,2,5,7,10,12:small_product<=product_q[PW-1:0];
                        1,6,11:lift<=$unsigned(small_product)+$unsigned(product_q[PW-1:0]);
                        3,8,13:begin
                            cross_q<=difference_product;
                            if(math_job==3)bc_sign<=(difference_product>0)?2'sd1:((difference_product<0)?-2'sd1:2'sd0);
                        end
                        4:incircle_q<=extended_product;
                        9,14:incircle_q<=incircle_q+extended_product;
                        default:begin end
                    endcase
                    if(math_job==14)state<=QUERY_EVAL;
                    else begin math_job<=math_job+1'b1;state<=MUL_RUN;end
                end
            end
            default:state<=CAPTURE;
        endcase
    end
endmodule
