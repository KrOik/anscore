// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Exact rational coordinate projection and premultiplied multistop paint.
module multistop_linear_gradient #(
    parameter integer MAX_STOPS=16,TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire [1:0] c_op,
    input wire [31:0] c_count,input wire [1:0] c_spread,
    input wire signed [17:0] c_x0,c_y0,c_x1,c_y1,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output reg [2:0] r_status,
    output reg [31:0] r_count,output reg [TAG_W-1:0] r_tag,
    input wire t_valid,output wire t_ready,input wire [16:0] t_offset,
    input wire [31:0] t_rgba, // premultiplied {R,G,B,A}
    input wire s_valid,output wire s_ready,
    input wire signed [17:0] s_px,s_py, // Q10.8 actual sample point
    input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output reg [31:0] m_rgba,
    output reg [15:0] m_x,m_y,output reg [TAG_W-1:0] m_tag,
    output reg m_degenerate,output wire configured,loading,busy
);
    localparam integer AW=MAX_STOPS>1?$clog2(MAX_STOPS):1;
    localparam [1:0] EMPTY=0,LOAD=1,RESIDENT=2;
    localparam [5:0] IDLE=0,CFG_X=1,CFG_Y=2,CFG_DONE=3,
        MUL_SEND=4,MUL_WAIT=5,STOP_DONE=6,STOP_WRITE=7,STOP_ACK=8,
        DOT_X=9,DOT_Y=10,DOT_DONE=11,SPREAD=12,MOD_DONE=13,
        DIV_SEND=14,DIV_WAIT=15,ROW_REQ=16,ROW_WAIT=17,ROW_TEST=18,
        COLOR_LEFT=19,COLOR_RIGHT=20,COLOR_DIV=21,COLOR_ROUND=22,HOLD=23;
    reg [5:0] state,mul_return,div_return;
    reg [1:0] mode,spread;
    reg response_valid,bad_stops;
    reg [31:0] expected,accepted;
    reg [16:0] previous_offset;
    reg signed [17:0] x0,y0;
    reg signed [18:0] dx,dy,px,py;
    reg [35:0] norm_x;
    reg [36:0] norm;
    reg signed [37:0] dot_x,dot;
    reg [52:0] mul_a;
    reg [17:0] mul_b;
    reg [70:0] product;
    reg [60:0] div_a,div_b,quotient,remainder;
    reg [31:0] pending_color,left_color,row_color,right_color;
    reg [52:0] pending_threshold,target,left_threshold,row_threshold;
    reg [52:0] left_weight,right_weight,denominator;
    reg [60:0] color_partial;
    reg [1:0] channel;
    reg [AW-1:0] scan_index;
    reg have_left;
    wire mul_ready,mul_valid,div_ready,div_valid,div_zero;
    wire [70:0] mul_product;
    wire [60:0] div_q,div_r;
    wire ram_ready,ram_valid,ram_error;
    wire [87:0] ram_data;
    wire signed [18:0] header_dx=$signed({c_x1[17],c_x1})-$signed({c_x0[17],c_x0});
    wire signed [18:0] header_dy=$signed({c_y1[17],c_y1})-$signed({c_y0[17],c_y0});
    wire signed [18:0] point_dx=$signed({s_px[17],s_px})-$signed({x0[17],x0});
    wire signed [18:0] point_dy=$signed({s_py[17],s_py})-$signed({y0[17],y0});
    function automatic [17:0] magnitude(input signed [18:0] a);
        reg [18:0] positive;
        begin positive=a[18] ? -a:a; magnitude=positive[17:0];end
    endfunction
    function automatic [7:0] lane(input [31:0] rgba,input [1:0] index);
        lane=rgba[index*8+:8];
    endfunction
    task automatic multiply(input [52:0] a,input [17:0] b,input [5:0] continuation);
        begin mul_a<=a;mul_b<=b;mul_return<=continuation;state<=MUL_SEND;end
    endtask
    task automatic divide(input [60:0] a,input [60:0] b,input [5:0] continuation);
        begin div_a<=a;div_b<=b;div_return<=continuation;state<=DIV_SEND;end
    endtask
    task automatic reply(input [2:0] status);
        begin r_status<=status;r_count<=accepted;r_tag<=c_tag;response_valid<=1;end
    endtask
    wire [36:0] mod_remainder=remainder[36:0];
    wire [36:0] repeated=(dot[37] && mod_remainder!=0)?norm-mod_remainder:mod_remainder;
    wire [36:0] reflected=quotient[0]?norm-mod_remainder:mod_remainder;
    wire [61:0] twice_remainder={remainder,1'b0};
    wire round_up=twice_remainder>{1'b0,div_b} ||
        (twice_remainder=={1'b0,div_b} && quotient[0]);
    wire [8:0] rounded={1'b0,quotient[7:0]}+{8'b0,round_up};
    wire signed [37:0] signed_product=(px[18]^dx[18]) ?
        -$signed({2'b0,product[35:0]}):$signed({2'b0,product[35:0]});
    wire signed [37:0] signed_y_product=(py[18]^dy[18]) ?
        -$signed({2'b0,product[35:0]}):$signed({2'b0,product[35:0]});
    wire [37:0] abs_dot=dot[37]?-dot:dot;
    assign configured=!rst && mode==RESIDENT;
    assign loading=!rst && mode==LOAD;
    assign busy=!rst && (state!=IDLE || response_valid);
    assign c_ready=!rst && state==IDLE && !response_valid;
    assign r_valid=!rst && response_valid;
    assign t_ready=!rst && state==IDLE && mode==LOAD && !response_valid && !c_valid && accepted<expected;
    assign s_ready=!rst && state==IDLE && mode==RESIDENT && !response_valid && !c_valid;
    assign m_valid=!rst && state==HOLD;
    img_hist_serial_multiply #(.A_W(53),.B_W(18)) shared_multiply(
        .clk(clk),.rst_n(!rst),.clk_en(1'b1),.s_valid(!rst && state==MUL_SEND),
        .s_ready(mul_ready),.s_a(mul_a),.s_b(mul_b),.m_valid(mul_valid),
        .m_ready(state==MUL_WAIT),.m_product(mul_product));
    integer_divider #(.W(61)) shared_divide(
        .clk(clk),.rst(rst),.s_valid(!rst && state==DIV_SEND),.s_ready(div_ready),
        .s_numerator(div_a),.s_denominator(div_b),.m_valid(div_valid),
        .m_ready(state==DIV_WAIT),.m_quotient(div_q),.m_remainder(div_r),.m_divzero(div_zero));
    cip_sync_sp_ram #(.DATA_WIDTH(88),.ADDR_WIDTH(AW),.DEPTH(MAX_STOPS)) stops(
        .clk(clk),.rst_n(!rst),.clk_en(1'b1),
        .req_valid(!rst && (state==STOP_WRITE || state==ROW_REQ)),.req_ready(ram_ready),
        .req_write(state==STOP_WRITE),
        .req_addr(state==STOP_WRITE?AW'(accepted):scan_index),
        .req_wdata({3'b0,pending_threshold,pending_color}),.req_wstrb(11'h7ff),
        .rsp_valid(ram_valid),.rsp_ready(state==STOP_ACK || state==ROW_WAIT),
        .rsp_rdata(ram_data),.rsp_error(ram_error));
    initial if(MAX_STOPS<1 || MAX_STOPS>16 || TAG_W<1 || TAG_W>32)
        $fatal(1,"multistop_linear_gradient MAX_STOPS 1..16 TAG_W 1..32");
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;mode<=EMPTY;response_valid<=0;bad_stops<=0;
            expected<=0;accepted<=0;previous_offset<=0;spread<=0;
            x0<=0;y0<=0;dx<=0;dy<=0;px<=0;py<=0;norm_x<=0;norm<=0;
            dot_x<=0;dot<=0;mul_a<=0;mul_b<=0;mul_return<=IDLE;product<=0;
            div_a<=0;div_b<=0;div_return<=IDLE;quotient<=0;remainder<=0;
            pending_color<=0;left_color<=0;row_color<=0;right_color<=0;
            pending_threshold<=0;target<=0;left_threshold<=0;row_threshold<=0;
            left_weight<=0;right_weight<=0;denominator<=0;color_partial<=0;
            channel<=0;scan_index<=0;have_left<=0;
            m_rgba<=0;m_x<=0;m_y<=0;m_tag<=0;m_degenerate<=0;
            r_status<=0;r_count<=0;r_tag<=0;
        end else begin
            if(response_valid && r_ready)response_valid<=0;
            case(state)
                IDLE:begin
                    if(c_valid && c_ready)begin
                        case(c_op)
                            0:begin
                                mode<=EMPTY;accepted<=0;expected<=0;bad_stops<=0;previous_offset<=0;
                                r_count<=0;r_tag<=c_tag;
                                if(c_count<1 || c_count>MAX_STOPS)begin r_status<=2;response_valid<=1;end
                                else if(c_spread>2)begin r_status<=3;response_valid<=1;end
                                else begin
                                    x0<=c_x0;y0<=c_y0;dx<=header_dx;dy<=header_dy;
                                    spread<=c_spread;expected<=c_count;state<=CFG_X;
                                end
                            end
                            1:begin
                                if(mode!=LOAD)reply(5);
                                else if(accepted!=expected)reply(1);
                                else if(bad_stops)reply(4);
                                else begin mode<=RESIDENT;reply(0);end
                            end
                            2:begin mode<=EMPTY;expected<=0;accepted<=0;reply(0);r_count<=0;end
                            default:reply(6);
                        endcase
                    end else if(t_valid && t_ready)begin
                        pending_color<=t_rgba;previous_offset<=t_offset;
                        if(t_offset>17'd65536 || (accepted!=0 && t_offset<previous_offset) ||
                            t_rgba[31:24]>t_rgba[7:0] || t_rgba[23:16]>t_rgba[7:0] ||
                            t_rgba[15:8]>t_rgba[7:0])bad_stops<=1;
                        multiply({16'b0,norm},{1'b0,t_offset},STOP_DONE);
                    end else if(s_valid && s_ready)begin
                        px<=point_dx;py<=point_dy;m_x<=s_x;m_y<=s_y;m_tag<=s_tag;
                        m_degenerate<=norm==0;have_left<=0;scan_index<=0;state<=DOT_X;
                    end
                end
                CFG_X:multiply({35'b0,magnitude(dx)},magnitude(dx),CFG_Y);
                CFG_Y:begin norm_x<=product[35:0];multiply({35'b0,magnitude(dy)},magnitude(dy),CFG_DONE);end
                CFG_DONE:begin
                    norm<={1'b0,norm_x}+{1'b0,product[35:0]};mode<=LOAD;
                    r_status<=0;r_count<=0;response_valid<=1;state<=IDLE;
                end
                MUL_SEND:if(mul_ready)state<=MUL_WAIT;
                MUL_WAIT:if(mul_valid)begin product<=mul_product;state<=mul_return;end
                STOP_DONE:begin pending_threshold<=product[52:0];state<=STOP_WRITE;end
                STOP_WRITE:if(ram_ready)state<=STOP_ACK;
                STOP_ACK:if(ram_valid)begin
                    if(ram_error)bad_stops<=1;
                    accepted<=accepted+1'b1;state<=IDLE;
                end
                DOT_X:multiply({35'b0,magnitude(px)},magnitude(dx),DOT_Y);
                DOT_Y:begin dot_x<=signed_product;multiply({35'b0,magnitude(py)},magnitude(dy),DOT_DONE);end
                DOT_DONE:begin dot<=dot_x+signed_y_product;state<=SPREAD;end
                SPREAD:begin
                    if(norm==0 || (spread==0 && dot<=0))begin target<=0;state<=ROW_REQ;end
                    else if(spread==0)begin
                        target<=dot>=$signed({1'b0,norm})?{norm,16'b0}:{dot[36:0],16'b0};
                        state<=ROW_REQ;
                    end else divide({23'b0,abs_dot},{24'b0,norm},MOD_DONE);
                end
                MOD_DONE:begin
                    target<=spread==1?{repeated,16'b0}:{reflected,16'b0};state<=ROW_REQ;
                end
                DIV_SEND:if(div_ready)state<=DIV_WAIT;
                DIV_WAIT:if(div_valid)begin quotient<=div_q;remainder<=div_r;state<=div_return;end
                ROW_REQ:if(ram_ready)state<=ROW_WAIT;
                ROW_WAIT:if(ram_valid)begin row_threshold<=ram_data[84:32];row_color<=ram_data[31:0];state<=ROW_TEST;end
                ROW_TEST:begin
                    if(target<row_threshold)begin
                        if(!have_left)begin m_rgba<=row_color;state<=HOLD;end
                        else begin
                            right_color<=row_color;left_weight<=row_threshold-target;
                            right_weight<=target-left_threshold;denominator<=row_threshold-left_threshold;
                            channel<=0;state<=COLOR_LEFT;
                        end
                    end else begin
                        left_threshold<=row_threshold;left_color<=row_color;have_left<=1;
                        if({{(32-AW){1'b0}},scan_index}+32'd1==expected)begin m_rgba<=row_color;state<=HOLD;end
                        else begin scan_index<=scan_index+1'b1;state<=ROW_REQ;end
                    end
                end
                COLOR_LEFT:multiply(left_weight,{10'b0,lane(left_color,channel)},COLOR_RIGHT);
                COLOR_RIGHT:begin
                    color_partial<=product[60:0];
                    multiply(right_weight,{10'b0,lane(right_color,channel)},COLOR_DIV);
                end
                COLOR_DIV:divide(color_partial+product[60:0],{8'b0,denominator},COLOR_ROUND);
                COLOR_ROUND:begin
                    m_rgba[channel*8+:8]<=rounded[7:0];
                    if(channel==3)state<=HOLD;
                    else begin channel<=channel+1'b1;state<=COLOR_LEFT;end
                end
                HOLD:if(m_ready)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
