// SPDX-License-Identifier: Apache-2.0
// Exact perspective UV for quantized positive reciprocal-W vertex values.
`default_nettype none
module perspective_uv_projector #(
    parameter integer Q_W=16, TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire signed [9:0] c_x0,c_y0,c_x1,c_y1,c_x2,c_y2,
    input wire [7:0] c_u0,c_v0,c_u1,c_v1,c_u2,c_v2,
    input wire [Q_W-1:0] c_q0,c_q1,c_q2,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output reg [1:0] r_status,
    output reg [TAG_W-1:0] r_tag,
    input wire s_valid,output wire s_ready,input wire [7:0] s_x,s_y,
    input wire s_first,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output reg [7:0] m_u,m_v,
    output wire [7:0] m_x,m_y,output wire m_first,m_covered,
    output wire [TAG_W-1:0] m_tag,output wire configured,busy
);
    generate if(Q_W<1||Q_W>16||TAG_W<1||TAG_W>32) begin: bad_parameters
        perspective_uv_projector_invalid_parameters invalid();
    end endgenerate
    localparam [4:0] IDLE=0,AREA_A=1,AREA_B=2,AREA_SAVE=3,
        COEF_SET=4,COEF_SAVE=5,EDGE_A=6,EDGE_B=7,EDGE_SAVE=8,
        EDGE_CHECK=9,MAC_SET=10,MAC_SAVE=11,DIV_INIT=12,DIVIDE=13,
        ROUND=14,OUTPUT_UV=15;
    reg [4:0] state;
    reg signed [9:0] vx[0:2],vy[0:2];
    reg [7:0] uv_u[0:2],uv_v[0:2];
    reg [Q_W-1:0] reciprocal[0:2];
    reg [23:0] coef_u[0:2],coef_v[0:2],weight[0:2];
    reg [23:0] mul_a,mul_b;
    wire [47:0] product=mul_a*mul_b;
    reg product_negative,negative_winding,valid_config,response_valid;
    reg signed [25:0] first_cross;
    // Only geometric products use this view. Their exact magnitudes fit 24 bits.
    wire signed [24:0] signed_product=product_negative ?
        -$signed({1'b0,product[23:0]}) : $signed({1'b0,product[23:0]});
    wire signed [25:0] cross_value=first_cross-$signed({signed_product[24],signed_product});
    wire signed [25:0] normalized_edge=negative_winding ? -cross_value : cross_value;
    reg [1:0] term,channel,edge_id;
    reg [7:0] px,py;
    reg first,covered,outside;
    reg [TAG_W-1:0] tag,config_tag;
    reg [41:0] denominator;
    reg [49:0] numerator_u,numerator_v,remainder,trial;
    reg [7:0] quotient;
    reg [2:0] bit_id;
    reg divide_v;
    reg signed [9:0] ax,ay,bx,by;
    wire signed [12:0] dx=$signed({{3{bx[9]}},bx})-$signed({{3{ax[9]}},ax});
    wire signed [12:0] dy=$signed({{3{by[9]}},by})-$signed({{3{ay[9]}},ay});
    wire signed [12:0] sample_dx=$signed({4'b0,px,1'b1})-$signed({{2{ax[9]}},ax,1'b0});
    wire signed [12:0] sample_dy=$signed({4'b0,py,1'b1})-$signed({{2{ay[9]}},ay,1'b0});
    wire signed [12:0] area_dx1=$signed({{3{vx[1][9]}},vx[1]})-$signed({{3{vx[0][9]}},vx[0]});
    wire signed [12:0] area_dy1=$signed({{3{vy[1][9]}},vy[1]})-$signed({{3{vy[0][9]}},vy[0]});
    wire signed [12:0] area_dx2=$signed({{3{vx[2][9]}},vx[2]})-$signed({{3{vx[0][9]}},vx[0]});
    wire signed [12:0] area_dy2=$signed({{3{vy[2][9]}},vy[2]})-$signed({{3{vy[0][9]}},vy[0]});
    wire [50:0] twice_remainder={remainder,1'b0};
    wire [50:0] wide_denominator={9'b0,denominator};
    wire round_up=(twice_remainder>wide_denominator)||
        ((twice_remainder==wide_denominator)&&quotient[0]);
    wire [8:0] rounded={1'b0,quotient}+{{8{1'b0}},round_up};
    function automatic [23:0] magnitude(input signed [12:0] value);
        reg [12:0] mag;
        begin mag=value[12] ? -value : value;magnitude={11'b0,mag};end
    endfunction
    always @* begin
        case(edge_id)
            0:begin ax=vx[1];ay=vy[1];bx=vx[2];by=vy[2];end
            1:begin ax=vx[2];ay=vy[2];bx=vx[0];by=vy[0];end
            default:begin ax=vx[0];ay=vy[0];bx=vx[1];by=vy[1];end
        endcase
    end
    assign c_ready=!rst&&state==IDLE&&!r_valid;
    assign r_valid=!rst&&response_valid;
    assign s_ready=!rst&&state==IDLE&&!r_valid&&!c_valid&&valid_config;
    assign m_valid=!rst&&state==OUTPUT_UV;
    assign m_x=px;assign m_y=py;assign m_tag=tag;assign m_first=first;assign m_covered=covered;
    assign configured=!rst&&valid_config;
    assign busy=!rst&&(state!=IDLE||r_valid);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;response_valid<=0;r_status<=0;r_tag<=0;valid_config<=0;
            mul_a<=0;mul_b<=0;product_negative<=0;negative_winding<=0;first_cross<=0;
            term<=0;channel<=0;edge_id<=0;px<=0;py<=0;first<=0;covered<=0;outside<=0;
            tag<=0;config_tag<=0;denominator<=0;numerator_u<=0;numerator_v<=0;
            remainder<=0;trial<=0;quotient<=0;bit_id<=0;divide_v<=0;m_u<=0;m_v<=0;
        end else begin
            if(r_valid&&r_ready)response_valid<=0;
            case(state)
                IDLE:begin
                    if(c_valid&&c_ready)begin
                        valid_config<=0;config_tag<=c_tag;
                        vx[0]<=c_x0;vy[0]<=c_y0;vx[1]<=c_x1;vy[1]<=c_y1;vx[2]<=c_x2;vy[2]<=c_y2;
                        uv_u[0]<=c_u0;uv_v[0]<=c_v0;uv_u[1]<=c_u1;uv_v[1]<=c_v1;uv_u[2]<=c_u2;uv_v[2]<=c_v2;
                        reciprocal[0]<=c_q0;reciprocal[1]<=c_q1;reciprocal[2]<=c_q2;
                        if(c_q0==0||c_q1==0||c_q2==0)begin response_valid<=1;r_status<=2;r_tag<=c_tag;end
                        else state<=AREA_A;
                    end else if(s_valid&&s_ready)begin
                        px<=s_x;py<=s_y;tag<=s_tag;first<=s_first;
                        edge_id<=0;outside<=0;covered<=0;state<=EDGE_A;
                    end
                end
                AREA_A:begin mul_a<=magnitude(area_dx1);mul_b<=magnitude(area_dy2);
                    product_negative<=area_dx1[12]^area_dy2[12];state<=AREA_B;end
                AREA_B:begin first_cross<=$signed({signed_product[24],signed_product});
                    mul_a<=magnitude(area_dy1);mul_b<=magnitude(area_dx2);
                    product_negative<=area_dy1[12]^area_dx2[12];state<=AREA_SAVE;end
                AREA_SAVE:begin
                    if(cross_value==0)begin response_valid<=1;r_status<=1;r_tag<=config_tag;state<=IDLE;end
                    else begin negative_winding<=cross_value<0;term<=0;channel<=0;state<=COEF_SET;end
                end
                COEF_SET:begin
                    mul_a<={{(24-Q_W){1'b0}},reciprocal[term]};
                    mul_b<=channel==0?{16'b0,uv_u[term]}:{16'b0,uv_v[term]};state<=COEF_SAVE;
                end
                COEF_SAVE:begin
                    if(channel==0)coef_u[term]<=product[23:0];else coef_v[term]<=product[23:0];
                    if(term==2)begin
                        if(channel==1)begin valid_config<=1;response_valid<=1;r_status<=0;r_tag<=config_tag;state<=IDLE;end
                        else begin term<=0;channel<=1;state<=COEF_SET;end
                    end else begin term<=term+1'b1;state<=COEF_SET;end
                end
                EDGE_A:begin mul_a<=magnitude(dx);mul_b<=magnitude(sample_dy);
                    product_negative<=dx[12]^sample_dy[12];state<=EDGE_B;end
                EDGE_B:begin first_cross<=$signed({signed_product[24],signed_product});
                    mul_a<=magnitude(dy);mul_b<=magnitude(sample_dx);
                    product_negative<=dy[12]^sample_dx[12];state<=EDGE_SAVE;end
                EDGE_SAVE:begin
                    weight[edge_id]<=normalized_edge[23:0];
                    if(normalized_edge<0)outside<=1;
                    if(edge_id==2)state<=EDGE_CHECK;else begin edge_id<=edge_id+1'b1;state<=EDGE_A;end
                end
                EDGE_CHECK:begin
                    if(outside)begin covered<=0;m_u<=0;m_v<=0;state<=OUTPUT_UV;end
                    else begin covered<=1;denominator<=0;numerator_u<=0;numerator_v<=0;
                        term<=0;channel<=0;state<=MAC_SET;end
                end
                MAC_SET:begin
                    mul_a<=weight[term];
                    case(channel)
                        0:mul_b<={{(24-Q_W){1'b0}},reciprocal[term]};
                        1:mul_b<=coef_u[term];
                        default:mul_b<=coef_v[term];
                    endcase
                    state<=MAC_SAVE;
                end
                MAC_SAVE:begin
                    case(channel)
                        0:denominator<=denominator+product[41:0];
                        1:numerator_u<=numerator_u+{2'b0,product};
                        default:numerator_v<=numerator_v+{2'b0,product};
                    endcase
                    if(term==2)begin
                        if(channel==2)state<=DIV_INIT;
                        else begin term<=0;channel<=channel+1'b1;state<=MAC_SET;end
                    end else begin term<=term+1'b1;state<=MAC_SET;end
                end
                DIV_INIT:begin remainder<=numerator_u;trial<={8'b0,denominator}<<7;
                    quotient<=0;bit_id<=7;divide_v<=0;state<=DIVIDE;end
                DIVIDE:begin
                    if(remainder>=trial)begin remainder<=remainder-trial;quotient[bit_id]<=1;end
                    if(bit_id==0)state<=ROUND;else begin bit_id<=bit_id-1'b1;trial<=trial>>1;end
                end
                ROUND:begin
                    // Convex positive-q interpolation is in 0..255, including RNE.
                    if(!divide_v)begin m_u<=rounded[7:0];remainder<=numerator_v;
                        trial<={8'b0,denominator}<<7;quotient<=0;bit_id<=7;divide_v<=1;state<=DIVIDE;end
                    else begin m_v<=rounded[7:0];state<=OUTPUT_UV;end
                end
                OUTPUT_UV:if(m_ready)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
