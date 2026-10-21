// Development draft. One elastic result register; division uses one shared
// 58-bit restoring divider for x and y. Modes 1 and 8 take 116 clk_en-enabled
// divider cycles from input acceptance to m_valid (58 cycles per coordinate).
// Other modes keep the registered response on the input-acceptance edge.
// Q16.16 signed inverse matrix maps destination coordinates to source
// coordinates. Output coordinates are unsigned Q16.8; negative/outside
// locations set border. Mode: 0 identity, 1 scale, 2 CW90, 3 180, 4 CW270,
// 5 mirror X, 6 flip Y, 7 affine, 8 perspective. All other modes return
// UNSUPPORTED.
module img_geo_inverse_map_v89c_baseline (
    input wire clk, rst_n, clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire [15:0] s_x, s_y,
    input wire s_sof, s_eol, s_eof,
    input wire [3:0] s_mode,
    input wire [15:0] s_src_width, s_src_height, s_dst_width, s_dst_height,
    input wire signed [31:0] s_h00, s_h01, s_h02,
    input wire signed [31:0] s_h10, s_h11, s_h12,
    input wire signed [31:0] s_h20, s_h21, s_h22,
    output reg m_valid,
    input wire m_ready,
    output reg [23:0] m_x_q8, m_y_q8,
    output reg m_border,
    output reg [3:0] m_error,
    output reg m_sof, m_eol, m_eof
);
localparam [3:0] E_OK=0, E_CONFIG=1, E_UNSUPPORTED=3, E_DIVZERO=4;
localparam [1:0] ST_IDLE=2'd0, ST_DIV_X=2'd1, ST_DIV_Y=2'd2;

reg [1:0] state;
reg signed [63:0] calc_x, calc_y;
reg signed [49:0] num_x, num_y, denom;
reg signed [31:0] dx, dy, sw, sh, dw, dh;
reg calc_border;
reg [3:0] calc_error;

// Scale coordinates are nonnegative 16x16 products shifted by Q8. Their
// exact numerator fits 40 bits; all division operands are extended to 58 bits
// so scale and perspective share the same iterative arithmetic unit.
wire [31:0] scale_product_x = s_x * s_src_width;
wire [31:0] scale_product_y = s_y * s_src_height;
wire [39:0] scale_numerator_x = {scale_product_x,8'd0};
wire [39:0] scale_numerator_y = {scale_product_y,8'd0};

// A signed 32x17 product covers a signed Q16.16 coefficient times a
// nonnegative 16-bit coordinate. Summing three such terms needs 50 bits.
wire signed [47:0] x_term_00 = $signed(s_h00) * $signed({1'b0,s_x});
wire signed [47:0] x_term_01 = $signed(s_h01) * $signed({1'b0,s_y});
wire signed [47:0] y_term_10 = $signed(s_h10) * $signed({1'b0,s_x});
wire signed [47:0] y_term_11 = $signed(s_h11) * $signed({1'b0,s_y});
wire signed [47:0] w_term_20 = $signed(s_h20) * $signed({1'b0,s_x});
wire signed [47:0] w_term_21 = $signed(s_h21) * $signed({1'b0,s_y});
wire signed [49:0] x_offset = {{18{s_h02[31]}},s_h02};
wire signed [49:0] y_offset = {{18{s_h12[31]}},s_h12};
wire signed [49:0] w_offset = {{18{s_h22[31]}},s_h22};
wire signed [57:0] perspective_num_x = {num_x,8'b0};
wire signed [57:0] perspective_num_y = {num_y,8'b0};
wire signed [57:0] perspective_den = {{8{denom[49]}},denom};

wire [15:0] safe_dst_width = s_dst_width==0 ? 16'd1 : s_dst_width;
wire [15:0] safe_dst_height = s_dst_height==0 ? 16'd1 : s_dst_height;
wire signed [57:0] scale_num_x_ext = $signed({18'd0,scale_numerator_x});
wire signed [57:0] scale_num_y_ext = $signed({18'd0,scale_numerator_y});
wire signed [57:0] scale_den_x_ext = $signed({42'd0,safe_dst_width});
wire signed [57:0] scale_den_y_ext = $signed({42'd0,safe_dst_height});
wire signed [57:0] input_div_num_x = s_mode==1 ? scale_num_x_ext : perspective_num_x;
wire signed [57:0] input_div_num_y = s_mode==1 ? scale_num_y_ext : perspective_num_y;
wire signed [57:0] input_div_den_x = s_mode==1 ? scale_den_x_ext : perspective_den;
wire signed [57:0] input_div_den_y = s_mode==1 ? scale_den_y_ext : perspective_den;

function [57:0] magnitude58;
    input signed [57:0] value;
    begin
        magnitude58 = value[57] ? (~value + 58'd1) : value;
    end
endfunction

// The shift/compare/subtract step processes one numerator bit per enabled
// clock. Remainder and quotient are unsigned magnitudes; signs are restored
// after the 58th iteration to match Verilog's truncation toward zero.
reg [57:0] div_dividend, div_divisor, div_remainder, div_quotient;
reg div_negative;
reg [5:0] div_count;
wire [57:0] div_remainder_shift = {div_remainder[56:0],div_dividend[57]};
wire div_subtract = div_remainder_shift >= div_divisor;
wire [57:0] div_remainder_next = div_subtract ?
    (div_remainder_shift - div_divisor) : div_remainder_shift;
wire [57:0] div_quotient_next = {div_quotient[56:0],div_subtract};
wire signed [57:0] div_result_signed = div_negative ?
    (~div_quotient_next + 58'd1) : div_quotient_next;

reg [57:0] work_y_dividend, work_y_divisor;
reg work_y_negative;
reg signed [57:0] work_x_q8;
reg [15:0] work_src_width, work_src_height;
reg [3:0] work_error;
reg work_sof, work_eol, work_eof;
wire signed [57:0] work_x_limit = $signed({34'd0,work_src_width,8'd0});
wire signed [57:0] work_y_limit = $signed({34'd0,work_src_height,8'd0});
wire start_division = (s_mode==4'd1 || s_mode==4'd8) && calc_error==E_OK;
wire can_accept = (state==ST_IDLE) && (!m_valid || m_ready);
// Match the surrounding geometry cores: clk_en freezes transfers and state,
// but does not gate ready. An input transfer occurs only on clk_en && valid
// && ready; upstream must keep valid/payload asserted through a CE pause.
assign s_ready = rst_n && can_accept;

always @* begin
    dx=$signed({16'd0,s_x}); dy=$signed({16'd0,s_y});
    sw=$signed({16'd0,s_src_width}); sh=$signed({16'd0,s_src_height});
    dw=$signed({16'd0,s_dst_width}); dh=$signed({16'd0,s_dst_height});
    calc_x=0; calc_y=0; num_x=0; num_y=0; denom=0;
    calc_border=0; calc_error=E_OK;
    if (sw==0 || sh==0 || dw==0 || dh==0 || dx>=dw || dy>=dh)
        calc_error=E_CONFIG;
    else begin
        case (s_mode)
            0: begin
                if (sw!=dw || sh!=dh) calc_error=E_CONFIG;
                calc_x=dx<<<8; calc_y=dy<<<8;
            end
            1: begin
                // Asymmetric grid: src_x=dst_x*src_width/dst_width.
                // Division is performed by the shared iterative unit.
            end
            2: begin
                if (dw!=sh || dh!=sw) calc_error=E_CONFIG;
                calc_x=dy<<<8; calc_y=(sh-1-dx)<<<8;
            end
            3: begin
                if (dw!=sw || dh!=sh) calc_error=E_CONFIG;
                calc_x=(sw-1-dx)<<<8; calc_y=(sh-1-dy)<<<8;
            end
            4: begin
                if (dw!=sh || dh!=sw) calc_error=E_CONFIG;
                calc_x=(sw-1-dy)<<<8; calc_y=dx<<<8;
            end
            5: begin
                if (dw!=sw || dh!=sh) calc_error=E_CONFIG;
                calc_x=(sw-1-dx)<<<8; calc_y=dy<<<8;
            end
            6: begin
                if (dw!=sw || dh!=sh) calc_error=E_CONFIG;
                calc_x=dx<<<8; calc_y=(sh-1-dy)<<<8;
            end
            7,8: begin
                num_x=$signed(x_term_00)+$signed(x_term_01)+x_offset;
                num_y=$signed(y_term_10)+$signed(y_term_11)+y_offset;
                if (s_mode==7) begin
                    calc_x=num_x>>>8; calc_y=num_y>>>8;
                end else begin
                    denom=$signed(w_term_20)+$signed(w_term_21)+w_offset;
                    if (denom==0) calc_error=E_DIVZERO;
                    // Perspective division is performed by the shared unit.
                end
            end
            default: calc_error=E_UNSUPPORTED;
        endcase
        if (calc_x<0 || calc_y<0 || calc_x>=(sw<<<8) || calc_y>=(sh<<<8))
            calc_border=1;
    end
    if (calc_error!=E_OK) calc_border=1;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state<=ST_IDLE;
        m_valid<=0; m_x_q8<=0; m_y_q8<=0; m_border<=0; m_error<=0;
        m_sof<=0; m_eol<=0; m_eof<=0;
        div_dividend<=0; div_divisor<=0; div_remainder<=0; div_quotient<=0;
        div_negative<=0; div_count<=0;
        work_y_dividend<=0; work_y_divisor<=0; work_y_negative<=0;
        work_x_q8<=0; work_src_width<=0; work_src_height<=0; work_error<=0;
        work_sof<=0; work_eol<=0; work_eof<=0;
    end else if (clk_en) begin
        case (state)
            ST_IDLE: begin
                if (m_valid && m_ready)
                    m_valid<=0;
                if (s_valid && s_ready) begin
                    if (start_division) begin
                        state<=ST_DIV_X;
                        m_valid<=0;
                        div_dividend<=magnitude58(input_div_num_x);
                        div_divisor<=magnitude58(input_div_den_x);
                        div_remainder<=0; div_quotient<=0; div_count<=0;
                        div_negative<=input_div_num_x[57]^input_div_den_x[57];
                        work_y_dividend<=magnitude58(input_div_num_y);
                        work_y_divisor<=magnitude58(input_div_den_y);
                        work_y_negative<=input_div_num_y[57]^input_div_den_y[57];
                        work_src_width<=s_src_width; work_src_height<=s_src_height;
                        work_error<=calc_error;
                        work_sof<=s_sof; work_eol<=s_eol; work_eof<=s_eof;
                    end else begin
                        m_valid<=1;
                        m_x_q8<=calc_border ? 24'd0 : calc_x[23:0];
                        m_y_q8<=calc_border ? 24'd0 : calc_y[23:0];
                        m_border<=calc_border; m_error<=calc_error;
                        m_sof<=s_sof; m_eol<=s_eol; m_eof<=s_eof;
                    end
                end
            end
            ST_DIV_X: begin
                div_dividend<={div_dividend[56:0],1'b0};
                div_remainder<=div_remainder_next;
                div_quotient<=div_quotient_next;
                if (div_count==6'd57) begin
                    work_x_q8<=div_result_signed;
                    div_dividend<=work_y_dividend;
                    div_divisor<=work_y_divisor;
                    div_remainder<=0; div_quotient<=0; div_count<=0;
                    div_negative<=work_y_negative;
                    state<=ST_DIV_Y;
                end else begin
                    div_count<=div_count+1'b1;
                end
            end
            ST_DIV_Y: begin
                div_dividend<={div_dividend[56:0],1'b0};
                div_remainder<=div_remainder_next;
                div_quotient<=div_quotient_next;
                if (div_count==6'd57) begin
                    state<=ST_IDLE;
                    m_valid<=1;
                    m_error<=work_error;
                    m_sof<=work_sof; m_eol<=work_eol; m_eof<=work_eof;
                    if (work_error!=E_OK || work_x_q8<0 || div_result_signed<0 ||
                        work_x_q8>=work_x_limit || div_result_signed>=work_y_limit) begin
                        m_x_q8<=0; m_y_q8<=0; m_border<=1;
                    end else begin
                        m_x_q8<=work_x_q8[23:0]; m_y_q8<=div_result_signed[23:0];
                        m_border<=0;
                    end
                end else begin
                    div_count<=div_count+1'b1;
                end
            end
            default: begin
                state<=ST_IDLE;
                m_valid<=0;
            end
        endcase
    end
end
endmodule
