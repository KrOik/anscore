// Development draft. One elastic result register; division uses one shared
// 58-bit restoring divider for x and y. Scale takes 240 clk_en-enabled cycles;
// perspective takes 241 (registered products, sums, split magnitudes,
// 116 divider cycles per coordinate and registered sign/range restoration).
// Affine mode 7 captures products, sums them, then validates at +2 enabled
// cycles. Other modes keep the response on the input-acceptance edge.
// Q16.16 signed inverse matrix maps destination coordinates to source
// coordinates. Output coordinates are unsigned Q16.8; negative/outside
// locations set border. Mode: 0 identity, 1 scale, 2 CW90, 3 180, 4 CW270,
// 5 mirror X, 6 flip Y, 7 affine, 8 perspective. All other modes return
// UNSUPPORTED.
module img_geo_inverse_map (
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
localparam [3:0] ST_IDLE=4'd0,
                 ST_DIV_X_LOW=4'd1, ST_DIV_X_HIGH=4'd2,
                 ST_DIV_X_RESTORE_LOW=4'd3,
                 ST_DIV_X_RESTORE_HIGH=4'd4,
                 ST_DIV_X_VALIDATE=4'd5,
                 ST_DIV_Y_LOW=4'd6, ST_DIV_Y_HIGH=4'd7,
                 ST_DIV_Y_RESTORE_LOW=4'd8,
                 ST_DIV_Y_RESTORE_HIGH=4'd9,
                 ST_DIV_Y_VALIDATE=4'd10,
                 ST_INPUT_MAG_LOW=4'd11, ST_INPUT_MAG_HIGH=4'd12,
                 ST_AFFINE_VALIDATE=4'd13, ST_MATRIX_SUM=4'd14;

reg [3:0] state;
reg signed [63:0] calc_x, calc_y;
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
// Products and offsets are captured before the full-precision matrix sums.
// The work-affine flag and dimensions travel with this one in-flight request.
reg signed [47:0] matrix_x0,matrix_x1,matrix_y0,matrix_y1,matrix_w0,matrix_w1;
reg signed [31:0] matrix_xoff,matrix_yoff,matrix_woff;
reg work_affine;
wire signed [49:0] matrix_num_x=$signed(matrix_x0)+$signed(matrix_x1)+
                              $signed({{18{matrix_xoff[31]}},matrix_xoff});
wire signed [49:0] matrix_num_y=$signed(matrix_y0)+$signed(matrix_y1)+
                              $signed({{18{matrix_yoff[31]}},matrix_yoff});
wire signed [49:0] matrix_den=$signed(matrix_w0)+$signed(matrix_w1)+
                            $signed({{18{matrix_woff[31]}},matrix_woff});

wire [15:0] safe_dst_width = s_dst_width==0 ? 16'd1 : s_dst_width;
wire [15:0] safe_dst_height = s_dst_height==0 ? 16'd1 : s_dst_height;
wire signed [57:0] scale_num_x_ext = $signed({18'd0,scale_numerator_x});
wire signed [57:0] scale_num_y_ext = $signed({18'd0,scale_numerator_y});
wire signed [57:0] scale_den_x_ext = $signed({42'd0,safe_dst_width});
wire signed [57:0] scale_den_y_ext = $signed({42'd0,safe_dst_height});

// Capture signed division operands before their magnitude conversion. Each
// two's-complement carry propagates over only 29 bits per enabled stage.
reg signed [57:0] raw_num_x,raw_num_y,raw_den_x,raw_den_y;
reg [28:0] mag_low_nx,mag_low_ny,mag_low_dx,mag_low_dy;
reg mag_carry_nx,mag_carry_ny,mag_carry_dx,mag_carry_dy;
function [28:0] magnitude_low;
    input [57:0] value;
    begin magnitude_low=value[57]?(~value[28:0]+29'd1):value[28:0]; end
endfunction
function [28:0] magnitude_high;
    input [57:0] value;
    input carry;
    begin magnitude_high=value[57]?(~value[57:29]+{{28{1'b0}},carry}):value[57:29]; end
endfunction

// The restoring step processes one numerator bit over two enabled clocks.
// Remainder and quotient are unsigned magnitudes; signs are restored after
// the 58th iteration to match Verilog's truncation toward zero.
reg [57:0] div_dividend, div_divisor, div_remainder, div_quotient;
reg div_negative;
reg [5:0] div_count;
// Split the restoring-divider subtract into two 29-bit stages. The low
// stage captures the shifted remainder, its low-half difference and borrow.
// The high stage resolves the remaining subtract and commits the remainder
// and quotient bit. Each half uses one enabled cycle, cutting the former
// 58-bit compare/subtract critical path without changing the quotient bits.
reg [57:0] div_remainder_shift;
// Registered byte subtraction prevents synthesis from rebuilding a58-bit chain.
reg [57:0] div_byte_difference;
reg [7:0] div_byte_less,div_byte_equal;
wire [57:0] div_remainder_shift_next = {div_remainder[56:0],div_dividend[57]};
wire [8:0] div_borrow;
wire [57:0] div_difference;
assign div_borrow[0]=1'b0;
assign div_borrow[1]=div_byte_less[0];
assign div_difference[7:0]=div_byte_difference[7:0]-div_borrow[0];
assign div_borrow[2]=div_byte_less[1]|(div_byte_equal[1]&div_byte_less[0]);
assign div_difference[15:8]=div_byte_difference[15:8]-div_borrow[1];
assign div_borrow[3]=div_byte_less[2]|(div_byte_equal[2]&div_byte_less[1])|(div_byte_equal[2]&div_byte_equal[1]&div_byte_less[0]);
assign div_difference[23:16]=div_byte_difference[23:16]-div_borrow[2];
assign div_borrow[4]=div_byte_less[3]|(div_byte_equal[3]&div_byte_less[2])|(div_byte_equal[3]&div_byte_equal[2]&div_byte_less[1])|(div_byte_equal[3]&div_byte_equal[2]&div_byte_equal[1]&div_byte_less[0]);
assign div_difference[31:24]=div_byte_difference[31:24]-div_borrow[3];
assign div_borrow[5]=div_byte_less[4]|(div_byte_equal[4]&div_byte_less[3])|(div_byte_equal[4]&div_byte_equal[3]&div_byte_less[2])|(div_byte_equal[4]&div_byte_equal[3]&div_byte_equal[2]&div_byte_less[1])|(div_byte_equal[4]&div_byte_equal[3]&div_byte_equal[2]&div_byte_equal[1]&div_byte_less[0]);
assign div_difference[39:32]=div_byte_difference[39:32]-div_borrow[4];
assign div_borrow[6]=div_byte_less[5]|(div_byte_equal[5]&div_byte_less[4])|(div_byte_equal[5]&div_byte_equal[4]&div_byte_less[3])|(div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_less[2])|(div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_equal[2]&div_byte_less[1])|(div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_equal[2]&div_byte_equal[1]&div_byte_less[0]);
assign div_difference[47:40]=div_byte_difference[47:40]-div_borrow[5];
assign div_borrow[7]=div_byte_less[6]|(div_byte_equal[6]&div_byte_less[5])|(div_byte_equal[6]&div_byte_equal[5]&div_byte_less[4])|(div_byte_equal[6]&div_byte_equal[5]&div_byte_equal[4]&div_byte_less[3])|(div_byte_equal[6]&div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_less[2])|(div_byte_equal[6]&div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_equal[2]&div_byte_less[1])|(div_byte_equal[6]&div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_equal[2]&div_byte_equal[1]&div_byte_less[0]);
assign div_difference[55:48]=div_byte_difference[55:48]-div_borrow[6];
assign div_borrow[8]=div_byte_less[7]|(div_byte_equal[7]&div_byte_less[6])|(div_byte_equal[7]&div_byte_equal[6]&div_byte_less[5])|(div_byte_equal[7]&div_byte_equal[6]&div_byte_equal[5]&div_byte_less[4])|(div_byte_equal[7]&div_byte_equal[6]&div_byte_equal[5]&div_byte_equal[4]&div_byte_less[3])|(div_byte_equal[7]&div_byte_equal[6]&div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_less[2])|(div_byte_equal[7]&div_byte_equal[6]&div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_equal[2]&div_byte_less[1])|(div_byte_equal[7]&div_byte_equal[6]&div_byte_equal[5]&div_byte_equal[4]&div_byte_equal[3]&div_byte_equal[2]&div_byte_equal[1]&div_byte_less[0]);
assign div_difference[57:56]=div_byte_difference[57:56]-div_borrow[7];
wire div_subtract = !div_borrow[8];
wire [57:0] div_remainder_next = div_subtract ? div_difference : div_remainder_shift;
wire [57:0] div_quotient_next = {div_quotient[56:0],div_subtract};
reg [57:0] work_y_dividend, work_y_divisor;
reg work_y_negative;
reg [28:0] restore_low, restore_high;
reg restore_carry;
reg [23:0] work_x_q8;
reg work_x_invalid;
reg [15:0] work_src_width, work_src_height;
reg [3:0] work_error;
reg work_sof, work_eol, work_eof;
wire start_division = (s_mode==4'd1 || s_mode==4'd8);
wire can_accept = (state==ST_IDLE) && (!m_valid || m_ready);
wire [28:0] restore_low_value = div_negative ?
    (~div_quotient[28:0] + 29'd1) : div_quotient[28:0];
wire restore_low_carry = div_negative && (div_quotient[28:0]==29'd0);
wire [28:0] restore_high_value = div_negative ?
    (~div_quotient[57:29] + {28'd0,restore_carry}) : div_quotient[57:29];
// A nonnegative signed Q8.8 result is outside the source image when any
// signed-result bit above bit 23 is set, or its integer part reaches the
// dimension. Keeping this 16-bit comparison after the registered 29-bit
// high-half restore avoids a single wide restore-plus-boundary output cone.
wire restore_x_invalid = restore_high[28] || (|restore_high[27:0]) ||
                         (|restore_low[28:24]) ||
                         (restore_low[23:8] >= work_src_width);
wire restore_y_invalid = restore_high[28] || (|restore_high[27:0]) ||
                         (|restore_low[28:24]) ||
                         (restore_low[23:8] >= work_src_height);
// raw_num captures the signed Q16.16 matrix sum shifted left by eight.
// Arithmetic >>>8 produces Q16.8; valid nonnegative coordinates require
// every bit above its 24-bit output to be zero before truncation.
wire affine_x_invalid = (|raw_num_x[57:40]) ||
                        (raw_num_x[39:24] >= work_src_width);
wire affine_y_invalid = (|raw_num_y[57:40]) ||
                        (raw_num_y[39:24] >= work_src_height);
// Match the surrounding geometry cores: clk_en freezes transfers and state,
// but does not gate ready. An input transfer occurs only on clk_en && valid
// && ready; upstream must keep valid/payload asserted through a CE pause.
assign s_ready = rst_n && can_accept;

always @* begin
    dx=$signed({16'd0,s_x}); dy=$signed({16'd0,s_y});
    sw=$signed({16'd0,s_src_width}); sh=$signed({16'd0,s_src_height});
    dw=$signed({16'd0,s_dst_width}); dh=$signed({16'd0,s_dst_height});
    calc_x=0; calc_y=0;
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
            7: begin
                // Full affine sum and range validation use separate stages.
            end
            8: begin
                // Divide-zero is checked only after the denominator is stored.
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
        raw_num_x<=0;raw_num_y<=0;raw_den_x<=0;raw_den_y<=0;
        matrix_x0<=0;matrix_x1<=0;matrix_y0<=0;matrix_y1<=0;
        matrix_w0<=0;matrix_w1<=0;
        matrix_xoff<=0;matrix_yoff<=0;matrix_woff<=0;work_affine<=0;
        mag_low_nx<=0;mag_low_ny<=0;mag_low_dx<=0;mag_low_dy<=0;
        mag_carry_nx<=0;mag_carry_ny<=0;mag_carry_dx<=0;mag_carry_dy<=0;
        m_valid<=0; m_x_q8<=0; m_y_q8<=0; m_border<=0; m_error<=0;
        m_sof<=0; m_eol<=0; m_eof<=0;
        div_dividend<=0; div_divisor<=0; div_remainder<=0; div_quotient<=0;
        div_remainder_shift<=0; div_byte_difference<=0; div_byte_less<=0;div_byte_equal<=0;
        div_negative<=0; div_count<=0;
        work_y_dividend<=0; work_y_divisor<=0; work_y_negative<=0;
        restore_low<=0; restore_high<=0; restore_carry<=0;
        work_x_q8<=0; work_x_invalid<=0;
        work_src_width<=0; work_src_height<=0; work_error<=0;
        work_sof<=0; work_eol<=0; work_eof<=0;
    end else if (clk_en) begin
        case (state)
            ST_IDLE: begin
                if (m_valid && m_ready)
                    m_valid<=0;
                if (s_valid && s_ready) begin
                    if (s_mode==4'd7 || s_mode==4'd8) begin
                        state<=ST_MATRIX_SUM;
                        m_valid<=0;
                        matrix_x0<=x_term_00;matrix_x1<=x_term_01;
                        matrix_y0<=y_term_10;matrix_y1<=y_term_11;
                        matrix_w0<=w_term_20;matrix_w1<=w_term_21;
                        matrix_xoff<=s_h02;matrix_yoff<=s_h12;matrix_woff<=s_h22;
                        work_affine<=s_mode==4'd7;
                        div_remainder<=0;div_quotient<=0;div_count<=0;
                        work_src_width<=s_src_width;work_src_height<=s_src_height;
                        work_error<=calc_error;
                        work_sof<=s_sof;work_eol<=s_eol;work_eof<=s_eof;
                    end else if (start_division) begin
                        state<=ST_INPUT_MAG_LOW;
                        m_valid<=0;
                        raw_num_x<=scale_num_x_ext;raw_num_y<=scale_num_y_ext;
                        raw_den_x<=scale_den_x_ext;raw_den_y<=scale_den_y_ext;
                        div_remainder<=0; div_quotient<=0; div_count<=0;
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
            ST_MATRIX_SUM: begin
                raw_num_x<={matrix_num_x,8'b0};raw_num_y<={matrix_num_y,8'b0};
                raw_den_x<={{8{matrix_den[49]}},matrix_den};
                raw_den_y<={{8{matrix_den[49]}},matrix_den};
                state<=work_affine ? ST_AFFINE_VALIDATE : ST_INPUT_MAG_LOW;
            end
            ST_AFFINE_VALIDATE: begin
                state<=ST_IDLE;
                m_valid<=1;
                m_error<=work_error;
                m_sof<=work_sof; m_eol<=work_eol; m_eof<=work_eof;
                if (work_error!=E_OK || affine_x_invalid || affine_y_invalid) begin
                    m_x_q8<=0; m_y_q8<=0; m_border<=1;
                end else begin
                    m_x_q8<=raw_num_x[39:16]; m_y_q8<=raw_num_y[39:16];
                    m_border<=0;
                end
            end
            ST_INPUT_MAG_LOW: begin
                if (work_error!=E_OK || raw_den_x==0) begin
                    state<=ST_IDLE;m_valid<=1;m_x_q8<=0;m_y_q8<=0;
                    m_border<=1;m_error<=work_error!=E_OK ? work_error : E_DIVZERO;
                    m_sof<=work_sof;m_eol<=work_eol;m_eof<=work_eof;
                end else begin
                    div_negative<=raw_num_x[57]^raw_den_x[57];
                    work_y_negative<=raw_num_y[57]^raw_den_y[57];
                    mag_low_nx<=magnitude_low(raw_num_x);
                    mag_low_ny<=magnitude_low(raw_num_y);
                    mag_low_dx<=magnitude_low(raw_den_x);
                    mag_low_dy<=magnitude_low(raw_den_y);
                    mag_carry_nx<=raw_num_x[57] && raw_num_x[28:0]==0;
                    mag_carry_ny<=raw_num_y[57] && raw_num_y[28:0]==0;
                    mag_carry_dx<=raw_den_x[57] && raw_den_x[28:0]==0;
                    mag_carry_dy<=raw_den_y[57] && raw_den_y[28:0]==0;
                    state<=ST_INPUT_MAG_HIGH;
                end
            end
            ST_INPUT_MAG_HIGH: begin
                div_dividend<={magnitude_high(raw_num_x,mag_carry_nx),mag_low_nx};
                div_divisor<={magnitude_high(raw_den_x,mag_carry_dx),mag_low_dx};
                work_y_dividend<={magnitude_high(raw_num_y,mag_carry_ny),mag_low_ny};
                work_y_divisor<={magnitude_high(raw_den_y,mag_carry_dy),mag_low_dy};
                state<=ST_DIV_X_LOW;
            end
            ST_DIV_X_LOW: begin
                div_remainder_shift<=div_remainder_shift_next;
                div_byte_difference[7:0]<=div_remainder_shift_next[7:0]-div_divisor[7:0];
                div_byte_less[0]<=div_remainder_shift_next[7:0]<div_divisor[7:0];
                div_byte_equal[0]<=div_remainder_shift_next[7:0]==div_divisor[7:0];
                div_byte_difference[15:8]<=div_remainder_shift_next[15:8]-div_divisor[15:8];
                div_byte_less[1]<=div_remainder_shift_next[15:8]<div_divisor[15:8];
                div_byte_equal[1]<=div_remainder_shift_next[15:8]==div_divisor[15:8];
                div_byte_difference[23:16]<=div_remainder_shift_next[23:16]-div_divisor[23:16];
                div_byte_less[2]<=div_remainder_shift_next[23:16]<div_divisor[23:16];
                div_byte_equal[2]<=div_remainder_shift_next[23:16]==div_divisor[23:16];
                div_byte_difference[31:24]<=div_remainder_shift_next[31:24]-div_divisor[31:24];
                div_byte_less[3]<=div_remainder_shift_next[31:24]<div_divisor[31:24];
                div_byte_equal[3]<=div_remainder_shift_next[31:24]==div_divisor[31:24];
                div_byte_difference[39:32]<=div_remainder_shift_next[39:32]-div_divisor[39:32];
                div_byte_less[4]<=div_remainder_shift_next[39:32]<div_divisor[39:32];
                div_byte_equal[4]<=div_remainder_shift_next[39:32]==div_divisor[39:32];
                div_byte_difference[47:40]<=div_remainder_shift_next[47:40]-div_divisor[47:40];
                div_byte_less[5]<=div_remainder_shift_next[47:40]<div_divisor[47:40];
                div_byte_equal[5]<=div_remainder_shift_next[47:40]==div_divisor[47:40];
                div_byte_difference[55:48]<=div_remainder_shift_next[55:48]-div_divisor[55:48];
                div_byte_less[6]<=div_remainder_shift_next[55:48]<div_divisor[55:48];
                div_byte_equal[6]<=div_remainder_shift_next[55:48]==div_divisor[55:48];
                div_byte_difference[57:56]<=div_remainder_shift_next[57:56]-div_divisor[57:56];
                div_byte_less[7]<=div_remainder_shift_next[57:56]<div_divisor[57:56];
                div_byte_equal[7]<=div_remainder_shift_next[57:56]==div_divisor[57:56];
                div_dividend<={div_dividend[56:0],1'b0};
                state<=ST_DIV_X_HIGH;
            end
            ST_DIV_X_HIGH: begin
                div_remainder<=div_remainder_next;
                div_quotient<=div_quotient_next;
                if (div_count==6'd57) begin
                    state<=ST_DIV_X_RESTORE_LOW;
                end else begin
                    div_count<=div_count+1'b1;
                    state<=ST_DIV_X_LOW;
                end
            end
            ST_DIV_X_RESTORE_LOW: begin
                restore_low<=restore_low_value;
                restore_carry<=restore_low_carry;
                state<=ST_DIV_X_RESTORE_HIGH;
            end
            ST_DIV_X_RESTORE_HIGH: begin
                restore_high<=restore_high_value;
                state<=ST_DIV_X_VALIDATE;
            end
            ST_DIV_X_VALIDATE: begin
                work_x_q8<=restore_low[23:0];
                work_x_invalid<=restore_x_invalid;
                div_dividend<=work_y_dividend;
                div_divisor<=work_y_divisor;
                div_remainder<=0; div_quotient<=0; div_count<=0;
                div_negative<=work_y_negative;
                state<=ST_DIV_Y_LOW;
            end
            ST_DIV_Y_LOW: begin
                div_remainder_shift<=div_remainder_shift_next;
                div_byte_difference[7:0]<=div_remainder_shift_next[7:0]-div_divisor[7:0];
                div_byte_less[0]<=div_remainder_shift_next[7:0]<div_divisor[7:0];
                div_byte_equal[0]<=div_remainder_shift_next[7:0]==div_divisor[7:0];
                div_byte_difference[15:8]<=div_remainder_shift_next[15:8]-div_divisor[15:8];
                div_byte_less[1]<=div_remainder_shift_next[15:8]<div_divisor[15:8];
                div_byte_equal[1]<=div_remainder_shift_next[15:8]==div_divisor[15:8];
                div_byte_difference[23:16]<=div_remainder_shift_next[23:16]-div_divisor[23:16];
                div_byte_less[2]<=div_remainder_shift_next[23:16]<div_divisor[23:16];
                div_byte_equal[2]<=div_remainder_shift_next[23:16]==div_divisor[23:16];
                div_byte_difference[31:24]<=div_remainder_shift_next[31:24]-div_divisor[31:24];
                div_byte_less[3]<=div_remainder_shift_next[31:24]<div_divisor[31:24];
                div_byte_equal[3]<=div_remainder_shift_next[31:24]==div_divisor[31:24];
                div_byte_difference[39:32]<=div_remainder_shift_next[39:32]-div_divisor[39:32];
                div_byte_less[4]<=div_remainder_shift_next[39:32]<div_divisor[39:32];
                div_byte_equal[4]<=div_remainder_shift_next[39:32]==div_divisor[39:32];
                div_byte_difference[47:40]<=div_remainder_shift_next[47:40]-div_divisor[47:40];
                div_byte_less[5]<=div_remainder_shift_next[47:40]<div_divisor[47:40];
                div_byte_equal[5]<=div_remainder_shift_next[47:40]==div_divisor[47:40];
                div_byte_difference[55:48]<=div_remainder_shift_next[55:48]-div_divisor[55:48];
                div_byte_less[6]<=div_remainder_shift_next[55:48]<div_divisor[55:48];
                div_byte_equal[6]<=div_remainder_shift_next[55:48]==div_divisor[55:48];
                div_byte_difference[57:56]<=div_remainder_shift_next[57:56]-div_divisor[57:56];
                div_byte_less[7]<=div_remainder_shift_next[57:56]<div_divisor[57:56];
                div_byte_equal[7]<=div_remainder_shift_next[57:56]==div_divisor[57:56];
                div_dividend<={div_dividend[56:0],1'b0};
                state<=ST_DIV_Y_HIGH;
            end
            ST_DIV_Y_HIGH: begin
                div_remainder<=div_remainder_next;
                div_quotient<=div_quotient_next;
                if (div_count==6'd57) begin
                    state<=ST_DIV_Y_RESTORE_LOW;
                end else begin
                    div_count<=div_count+1'b1;
                    state<=ST_DIV_Y_LOW;
                end
            end
            ST_DIV_Y_RESTORE_LOW: begin
                restore_low<=restore_low_value;
                restore_carry<=restore_low_carry;
                state<=ST_DIV_Y_RESTORE_HIGH;
            end
            ST_DIV_Y_RESTORE_HIGH: begin
                restore_high<=restore_high_value;
                state<=ST_DIV_Y_VALIDATE;
            end
            ST_DIV_Y_VALIDATE: begin
                state<=ST_IDLE;
                m_valid<=1;
                m_error<=work_error;
                m_sof<=work_sof; m_eol<=work_eol; m_eof<=work_eof;
                if (work_error!=E_OK || work_x_invalid || restore_y_invalid) begin
                    m_x_q8<=0; m_y_q8<=0; m_border<=1;
                end else begin
                    m_x_q8<=work_x_q8; m_y_q8<=restore_low[23:0];
                    m_border<=0;
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
