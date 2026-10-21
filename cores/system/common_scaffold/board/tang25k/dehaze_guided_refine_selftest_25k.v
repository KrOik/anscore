`default_nettype none

// Tang Primer 25K board self-test for img_dh_guided_refine.
// A fixed 3x2 RGB frame is converted to a BT.601-style 8-bit guide plane and
// paired with a fixed Q0.15 transmission plane. Every refined pixel is checked
// against an independent golden vector before a single UART verdict line is
// emitted on C3 at 115200 baud (50 MHz oscillator on E2).
module dehaze_guided_refine_selftest_25k #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input  wire clk,
    input  wire uart_rx_pin,
    output reg  uart_tx,
    output wire dbg_uart
);
    localparam integer BAUD_DIV = CLK_HZ / BAUD;
    localparam integer FRAME_WIDTH = 3;
    localparam integer FRAME_HEIGHT = 2;
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    // report_index stops before REPORT_LENGTH, so 566 transmits bytes 0..565:
    // diagnostics end with one CR/LF pair at offsets 564 and 565.
    localparam integer REPORT_LENGTH = 566;
    localparam [31:0] GOLDEN_DIGEST = 32'h69B9F759;
    localparam [2:0] ST_COMMAND = 0, ST_INPUT = 1, ST_OUTPUT = 2,
                     ST_RESPONSE = 3, ST_REPORT = 4, ST_DONE = 5;

    // The existing Tang25K harnesses use this POR pattern. The 16-bit
    // counter releases reset after about 655 us at the 50 MHz E2 oscillator.
    reg [15:0] por_count = 16'd0;
    always @(posedge clk) begin
        if (!por_count[15]) por_count <= por_count + 16'd1;
    end
    wire rst_n = por_count[15];

    reg [2:0] state;
    reg [2:0] input_index, output_index;
    reg [31:0] output_digest;
    reg failed, passed;
    reg [7:0] error_code;
    reg [23:0] watchdog;
    reg mismatch_seen;
    reg [2:0] mismatch_index;
    reg [15:0] mismatch_pixel;
    reg [63:0] first_quotient;
    reg signed [47:0] first_a_value, first_b_value;
    reg [31:0] first_sum_i, first_sum_p, first_sum_ii, first_sum_ip;
    reg [2:0] frame_error_flags;
    reg signed [63:0] first_a_numerator, first_a_denominator;
    reg signed [63:0] first_b_numerator, first_b_denominator;
    reg signed [63:0] second_q_numerator, second_q_denominator, second_q_quotient;
    reg signed [63:0] first_q_sum_a, first_q_sum_b;
    reg signed [63:0] first_q_numerator, first_q_denominator;
    reg signed [47:0] a_coeff_1, a_coeff_3, a_coeff_4;
    reg signed [47:0] b_coeff_1, b_coeff_3, b_coeff_4;
    reg [31:0] a3_sum_i, a3_sum_p, a3_sum_ii, a3_sum_ip;
    reg [31:0] a4_sum_i, a4_sum_p, a4_sum_ii, a4_sum_ip;

    wire cmd_ready, rsp_valid;
    wire [3:0] rsp_error;
    wire [15:0] m_t;
    wire signed [63:0] debug_divide_quotient;
    wire signed [47:0] debug_first_a_value, debug_first_b_value;
    wire [31:0] debug_first_sum_i, debug_first_sum_p;
    wire [31:0] debug_first_sum_ii, debug_first_sum_ip;
    wire [2:0] debug_frame_error_flags;
    wire signed [63:0] debug_first_a_numerator, debug_first_a_denominator;
    wire signed [63:0] debug_first_b_numerator, debug_first_b_denominator;
    wire signed [63:0] debug_second_q_numerator, debug_second_q_denominator;
    wire signed [63:0] debug_first_q_sum_a, debug_first_q_sum_b;
    wire signed [63:0] debug_first_q_numerator, debug_first_q_denominator;
    wire signed [47:0] debug_a_coeff_1, debug_a_coeff_3, debug_a_coeff_4;
    wire signed [47:0] debug_b_coeff_1, debug_b_coeff_3, debug_b_coeff_4;
    wire [31:0] debug_a3_sum_i, debug_a3_sum_p, debug_a3_sum_ii, debug_a3_sum_ip;
    wire [31:0] debug_a4_sum_i, debug_a4_sum_p, debug_a4_sum_ii, debug_a4_sum_ip;
    wire m_valid, m_sof, m_eol, m_eof;
    wire s_ready, rsp_ready;

    function [23:0] fixed_rgb;
        input [2:0] index;
        begin
            case (index)
                0: fixed_rgb = 24'h204060; // R=32, G=64,  B=96
                1: fixed_rgb = 24'h602850; // R=96, G=40,  B=80
                2: fixed_rgb = 24'h147830; // R=20, G=120, B=48
                3: fixed_rgb = 24'h785028; // R=120,G=80,  B=40
                4: fixed_rgb = 24'h402010; // R=64, G=32,  B=16
                default: fixed_rgb = 24'hB47030; // R=180,G=112,B=48
            endcase
        end
    endfunction

    function [7:0] fixed_guide;
        input [2:0] index;
        reg [23:0] rgb;
        reg [31:0] weighted;
        begin
            rgb = fixed_rgb(index);
            weighted = 32'd77 * rgb[23:16] +
                       32'd150 * rgb[15:8] +
                       32'd29 * rgb[7:0] + 32'd128;
            fixed_guide = weighted[15:8];
        end
    endfunction

    function [15:0] fixed_transmission;
        input [2:0] index;
        begin
            case (index)
                0: fixed_transmission = 16'd28000;
                1: fixed_transmission = 16'd22000;
                2: fixed_transmission = 16'd15000;
                3: fixed_transmission = 16'd24000;
                4: fixed_transmission = 16'd11000;
                default: fixed_transmission = 16'd9000;
            endcase
        end
    endfunction

    function [15:0] golden_pixel;
        input [2:0] index;
        begin
            case (index)
                0: golden_pixel = 16'd21477;
                1: golden_pixel = 16'd19443;
                2: golden_pixel = 16'd15311;
                3: golden_pixel = 16'd22955;
                4: golden_pixel = 16'd18362;
                default: golden_pixel = 16'd11450;
            endcase
        end
    endfunction

    wire s_valid = state == ST_INPUT;
    wire [7:0] s_guide_gray = fixed_guide(input_index);
    wire [15:0] s_t = fixed_transmission(input_index);
    wire s_sof = input_index == 0;
    wire s_eol = (input_index == 2) || (input_index == 5);
    wire m_ready = state == ST_OUTPUT;
    assign rsp_ready = state == ST_RESPONSE;
    assign dbg_uart = passed;

    img_dh_guided_refine #(
        .MAX_WIDTH(FRAME_WIDTH), .MAX_HEIGHT(FRAME_HEIGHT), .MAX_RADIUS(1)
    ) guided_refine_i (
        .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
        .cfg_valid(state == ST_COMMAND), .cfg_ready(cmd_ready),
        .cfg_width(16'd3), .cfg_height(16'd2), .cfg_radius(4'd1),
        .cfg_epsilon(32'd4),
        .s_guide_gray(s_guide_gray), .s_t(s_t), .s_valid(s_valid),
        .s_sof(s_sof), .s_eol(s_eol), .s_ready(s_ready),
        .m_t(m_t), .m_valid(m_valid), .m_sof(m_sof), .m_eol(m_eol),
        .m_eof(m_eof), .m_ready(m_ready),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_error(rsp_error),
        .debug_divide_quotient(debug_divide_quotient),
        .debug_first_a_value(debug_first_a_value),
        .debug_first_b_value(debug_first_b_value),
        .debug_first_sum_i(debug_first_sum_i),
        .debug_first_sum_p(debug_first_sum_p),
        .debug_first_sum_ii(debug_first_sum_ii),
        .debug_first_sum_ip(debug_first_sum_ip),
        .debug_frame_error_flags(debug_frame_error_flags),
        .debug_first_a_numerator(debug_first_a_numerator),
        .debug_first_a_denominator(debug_first_a_denominator),
        .debug_first_b_numerator(debug_first_b_numerator),
        .debug_first_b_denominator(debug_first_b_denominator),
        .debug_second_q_numerator(debug_second_q_numerator),
        .debug_second_q_denominator(debug_second_q_denominator),
        .debug_first_q_sum_a(debug_first_q_sum_a),
        .debug_first_q_sum_b(debug_first_q_sum_b),
        .debug_first_q_numerator(debug_first_q_numerator),
        .debug_first_q_denominator(debug_first_q_denominator),
        .debug_a_coeff_1(debug_a_coeff_1),
        .debug_a_coeff_3(debug_a_coeff_3),
        .debug_a_coeff_4(debug_a_coeff_4),
        .debug_b_coeff_1(debug_b_coeff_1),
        .debug_b_coeff_3(debug_b_coeff_3),
        .debug_b_coeff_4(debug_b_coeff_4),
        .debug_a3_sum_i(debug_a3_sum_i),
        .debug_a3_sum_p(debug_a3_sum_p),
        .debug_a3_sum_ii(debug_a3_sum_ii),
        .debug_a3_sum_ip(debug_a3_sum_ip),
        .debug_a4_sum_i(debug_a4_sum_i),
        .debug_a4_sum_p(debug_a4_sum_p),
        .debug_a4_sum_ii(debug_a4_sum_ii),
        .debug_a4_sum_ip(debug_a4_sum_ip)
    );

    function [7:0] hex_ascii;
        input [3:0] value;
        begin
            if (value < 10) hex_ascii = 8'h30 + value;
            else hex_ascii = 8'h41 + value - 10;
        end
    endfunction

    function [7:0] report_byte;
        input [9:0] index;
        input is_fail;
        input [31:0] digest;
        input [7:0] code;
        input [2:0] bad_index;
        input [15:0] bad_pixel;
        input [63:0] quotient;
        input [47:0] a_value;
        input [47:0] b_value;
        input [31:0] sum_i;
        input [31:0] sum_p;
        input [31:0] sum_ii;
        input [31:0] sum_ip;
        input [2:0] frame_flags;
        input [63:0] a_numerator;
        input [63:0] a_denominator;
        input [63:0] b_numerator;
        input [63:0] b_denominator;
        input [63:0] q_numerator;
        input [63:0] q_denominator;
        input [63:0] q_quotient;
        input [63:0] q0_sum_a;
        input [63:0] q0_sum_b;
        input [63:0] q0_numerator;
        input [63:0] q0_denominator;
        input [63:0] q0_quotient;
        input [47:0] a1;
        input [47:0] a3;
        input [47:0] a4;
        input [47:0] b1;
        input [47:0] b3;
        input [47:0] b4;
        input [31:0] sum_i3;
        input [31:0] sum_p3;
        input [31:0] sum_ii3;
        input [31:0] sum_ip3;
        input [31:0] sum_i4;
        input [31:0] sum_p4;
        input [31:0] sum_ii4;
        input [31:0] sum_ip4;
        begin
            case (index)
                0: report_byte = "D";
                1: report_byte = "H";
                2: report_byte = "R";
                3: report_byte = "F";
                4: report_byte = " ";
                5: report_byte = is_fail ? "F" : "P";
                6: report_byte = "A";
                7: report_byte = is_fail ? "I" : "S";
                8: report_byte = is_fail ? "L" : "S";
                9: report_byte = " ";
                10: report_byte = "D";
                11: report_byte = "=";
                12: report_byte = hex_ascii(digest[31:28]);
                13: report_byte = hex_ascii(digest[27:24]);
                14: report_byte = hex_ascii(digest[23:20]);
                15: report_byte = hex_ascii(digest[19:16]);
                16: report_byte = hex_ascii(digest[15:12]);
                17: report_byte = hex_ascii(digest[11:8]);
                18: report_byte = hex_ascii(digest[7:4]);
                19: report_byte = hex_ascii(digest[3:0]);
                20: report_byte = " ";
                21: report_byte = "E";
                22: report_byte = "=";
                23: report_byte = hex_ascii(code[7:4]);
                24: report_byte = hex_ascii(code[3:0]);
                25: report_byte = " ";
                26: report_byte = "I";
                27: report_byte = "=";
                28: report_byte = hex_ascii({1'b0, bad_index});
                29: report_byte = " ";
                30: report_byte = "M";
                31: report_byte = "=";
                32: report_byte = hex_ascii(bad_pixel[15:12]);
                33: report_byte = hex_ascii(bad_pixel[11:8]);
                34: report_byte = hex_ascii(bad_pixel[7:4]);
                35: report_byte = hex_ascii(bad_pixel[3:0]);
                36: report_byte = " ";
                37: report_byte = "A";
                38: report_byte = "=";
                39: report_byte = hex_ascii(a_value[47:44]);
                40: report_byte = hex_ascii(a_value[43:40]);
                41: report_byte = hex_ascii(a_value[39:36]);
                42: report_byte = hex_ascii(a_value[35:32]);
                43: report_byte = hex_ascii(a_value[31:28]);
                44: report_byte = hex_ascii(a_value[27:24]);
                45: report_byte = hex_ascii(a_value[23:20]);
                46: report_byte = hex_ascii(a_value[19:16]);
                47: report_byte = hex_ascii(a_value[15:12]);
                48: report_byte = hex_ascii(a_value[11:8]);
                49: report_byte = hex_ascii(a_value[7:4]);
                50: report_byte = hex_ascii(a_value[3:0]);
                54: report_byte = hex_ascii(b_value[47:44]);
                51: report_byte = " ";
                52: report_byte = "B";
                53: report_byte = "=";
                55: report_byte = hex_ascii(b_value[43:40]);
                56: report_byte = hex_ascii(b_value[39:36]);
                57: report_byte = hex_ascii(b_value[35:32]);
                58: report_byte = hex_ascii(b_value[31:28]);
                59: report_byte = hex_ascii(b_value[27:24]);
                60: report_byte = hex_ascii(b_value[23:20]);
                61: report_byte = hex_ascii(b_value[19:16]);
                62: report_byte = hex_ascii(b_value[15:12]);
                63: report_byte = hex_ascii(b_value[11:8]);
                64: report_byte = hex_ascii(b_value[7:4]);
                65: report_byte = hex_ascii(b_value[3:0]);
                66: report_byte = " ";
                67: report_byte = "S";
                68: report_byte = "I";
                69: report_byte = "=";
                70: report_byte = hex_ascii(sum_i[31:28]);
                71: report_byte = hex_ascii(sum_i[27:24]);
                72: report_byte = hex_ascii(sum_i[23:20]);
                73: report_byte = hex_ascii(sum_i[19:16]);
                74: report_byte = hex_ascii(sum_i[15:12]);
                75: report_byte = hex_ascii(sum_i[11:8]);
                76: report_byte = hex_ascii(sum_i[7:4]);
                77: report_byte = hex_ascii(sum_i[3:0]);
                78: report_byte = " ";
                79: report_byte = "S";
                80: report_byte = "P";
                81: report_byte = "=";
                82: report_byte = hex_ascii(sum_p[31:28]);
                83: report_byte = hex_ascii(sum_p[27:24]);
                84: report_byte = hex_ascii(sum_p[23:20]);
                85: report_byte = hex_ascii(sum_p[19:16]);
                86: report_byte = hex_ascii(sum_p[15:12]);
                87: report_byte = hex_ascii(sum_p[11:8]);
                88: report_byte = hex_ascii(sum_p[7:4]);
                89: report_byte = hex_ascii(sum_p[3:0]);
                90: report_byte = " ";
                91: report_byte = "S";
                92: report_byte = "I";
                93: report_byte = "I";
                94: report_byte = "=";
                95: report_byte = hex_ascii(sum_ii[31:28]);
                96: report_byte = hex_ascii(sum_ii[27:24]);
                97: report_byte = hex_ascii(sum_ii[23:20]);
                98: report_byte = hex_ascii(sum_ii[19:16]);
                99: report_byte = hex_ascii(sum_ii[15:12]);
                100: report_byte = hex_ascii(sum_ii[11:8]);
                101: report_byte = hex_ascii(sum_ii[7:4]);
                102: report_byte = hex_ascii(sum_ii[3:0]);
                103: report_byte = " ";
                104: report_byte = "S";
                105: report_byte = "I";
                106: report_byte = "P";
                107: report_byte = "=";
                108: report_byte = hex_ascii(sum_ip[31:28]);
                109: report_byte = hex_ascii(sum_ip[27:24]);
                110: report_byte = hex_ascii(sum_ip[23:20]);
                111: report_byte = hex_ascii(sum_ip[19:16]);
                112: report_byte = hex_ascii(sum_ip[15:12]);
                113: report_byte = hex_ascii(sum_ip[11:8]);
                114: report_byte = hex_ascii(sum_ip[7:4]);
                115: report_byte = hex_ascii(sum_ip[3:0]);
                116: report_byte = " ";
                117: report_byte = "F";
                118: report_byte = "=";
                119: report_byte = hex_ascii({1'b0, frame_flags});
                120: report_byte = " ";
                121: report_byte = "A";
                122: report_byte = "N";
                123: report_byte = "=";
                124: report_byte = hex_ascii(a_numerator[63:60]);
                125: report_byte = hex_ascii(a_numerator[59:56]);
                126: report_byte = hex_ascii(a_numerator[55:52]);
                127: report_byte = hex_ascii(a_numerator[51:48]);
                128: report_byte = hex_ascii(a_numerator[47:44]);
                129: report_byte = hex_ascii(a_numerator[43:40]);
                130: report_byte = hex_ascii(a_numerator[39:36]);
                131: report_byte = hex_ascii(a_numerator[35:32]);
                132: report_byte = hex_ascii(a_numerator[31:28]);
                133: report_byte = hex_ascii(a_numerator[27:24]);
                134: report_byte = hex_ascii(a_numerator[23:20]);
                135: report_byte = hex_ascii(a_numerator[19:16]);
                136: report_byte = hex_ascii(a_numerator[15:12]);
                137: report_byte = hex_ascii(a_numerator[11:8]);
                138: report_byte = hex_ascii(a_numerator[7:4]);
                139: report_byte = hex_ascii(a_numerator[3:0]);
                140: report_byte = " ";
                141: report_byte = "A";
                142: report_byte = "D";
                143: report_byte = "=";
                144: report_byte = hex_ascii(a_denominator[63:60]);
                145: report_byte = hex_ascii(a_denominator[59:56]);
                146: report_byte = hex_ascii(a_denominator[55:52]);
                147: report_byte = hex_ascii(a_denominator[51:48]);
                148: report_byte = hex_ascii(a_denominator[47:44]);
                149: report_byte = hex_ascii(a_denominator[43:40]);
                150: report_byte = hex_ascii(a_denominator[39:36]);
                151: report_byte = hex_ascii(a_denominator[35:32]);
                152: report_byte = hex_ascii(a_denominator[31:28]);
                153: report_byte = hex_ascii(a_denominator[27:24]);
                154: report_byte = hex_ascii(a_denominator[23:20]);
                155: report_byte = hex_ascii(a_denominator[19:16]);
                156: report_byte = hex_ascii(a_denominator[15:12]);
                157: report_byte = hex_ascii(a_denominator[11:8]);
                158: report_byte = hex_ascii(a_denominator[7:4]);
                159: report_byte = hex_ascii(a_denominator[3:0]);
                160: report_byte = " ";
                161: report_byte = "B";
                162: report_byte = "N";
                163: report_byte = "=";
                164: report_byte = hex_ascii(b_numerator[63:60]);
                165: report_byte = hex_ascii(b_numerator[59:56]);
                166: report_byte = hex_ascii(b_numerator[55:52]);
                167: report_byte = hex_ascii(b_numerator[51:48]);
                168: report_byte = hex_ascii(b_numerator[47:44]);
                169: report_byte = hex_ascii(b_numerator[43:40]);
                170: report_byte = hex_ascii(b_numerator[39:36]);
                171: report_byte = hex_ascii(b_numerator[35:32]);
                172: report_byte = hex_ascii(b_numerator[31:28]);
                173: report_byte = hex_ascii(b_numerator[27:24]);
                174: report_byte = hex_ascii(b_numerator[23:20]);
                175: report_byte = hex_ascii(b_numerator[19:16]);
                176: report_byte = hex_ascii(b_numerator[15:12]);
                177: report_byte = hex_ascii(b_numerator[11:8]);
                178: report_byte = hex_ascii(b_numerator[7:4]);
                179: report_byte = hex_ascii(b_numerator[3:0]);
                180: report_byte = " ";
                181: report_byte = "B";
                182: report_byte = "D";
                183: report_byte = "=";
                184: report_byte = hex_ascii(b_denominator[63:60]);
                185: report_byte = hex_ascii(b_denominator[59:56]);
                186: report_byte = hex_ascii(b_denominator[55:52]);
                187: report_byte = hex_ascii(b_denominator[51:48]);
                188: report_byte = hex_ascii(b_denominator[47:44]);
                189: report_byte = hex_ascii(b_denominator[43:40]);
                190: report_byte = hex_ascii(b_denominator[39:36]);
                191: report_byte = hex_ascii(b_denominator[35:32]);
                192: report_byte = hex_ascii(b_denominator[31:28]);
                193: report_byte = hex_ascii(b_denominator[27:24]);
                194: report_byte = hex_ascii(b_denominator[23:20]);
                195: report_byte = hex_ascii(b_denominator[19:16]);
                196: report_byte = hex_ascii(b_denominator[15:12]);
                197: report_byte = hex_ascii(b_denominator[11:8]);
                198: report_byte = hex_ascii(b_denominator[7:4]);
                199: report_byte = hex_ascii(b_denominator[3:0]);
                200: report_byte = " ";
                201: report_byte = "Q";
                202: report_byte = "M";
                203: report_byte = "=";
                204: report_byte = hex_ascii(q_numerator[63:60]);
                205: report_byte = hex_ascii(q_numerator[59:56]);
                206: report_byte = hex_ascii(q_numerator[55:52]);
                207: report_byte = hex_ascii(q_numerator[51:48]);
                208: report_byte = hex_ascii(q_numerator[47:44]);
                209: report_byte = hex_ascii(q_numerator[43:40]);
                210: report_byte = hex_ascii(q_numerator[39:36]);
                211: report_byte = hex_ascii(q_numerator[35:32]);
                212: report_byte = hex_ascii(q_numerator[31:28]);
                213: report_byte = hex_ascii(q_numerator[27:24]);
                214: report_byte = hex_ascii(q_numerator[23:20]);
                215: report_byte = hex_ascii(q_numerator[19:16]);
                216: report_byte = hex_ascii(q_numerator[15:12]);
                217: report_byte = hex_ascii(q_numerator[11:8]);
                218: report_byte = hex_ascii(q_numerator[7:4]);
                219: report_byte = hex_ascii(q_numerator[3:0]);
                220: report_byte = " ";
                221: report_byte = "R";
                222: report_byte = "M";
                223: report_byte = "=";
                224: report_byte = hex_ascii(q_denominator[63:60]);
                225: report_byte = hex_ascii(q_denominator[59:56]);
                226: report_byte = hex_ascii(q_denominator[55:52]);
                227: report_byte = hex_ascii(q_denominator[51:48]);
                228: report_byte = hex_ascii(q_denominator[47:44]);
                229: report_byte = hex_ascii(q_denominator[43:40]);
                230: report_byte = hex_ascii(q_denominator[39:36]);
                231: report_byte = hex_ascii(q_denominator[35:32]);
                232: report_byte = hex_ascii(q_denominator[31:28]);
                233: report_byte = hex_ascii(q_denominator[27:24]);
                234: report_byte = hex_ascii(q_denominator[23:20]);
                235: report_byte = hex_ascii(q_denominator[19:16]);
                236: report_byte = hex_ascii(q_denominator[15:12]);
                237: report_byte = hex_ascii(q_denominator[11:8]);
                238: report_byte = hex_ascii(q_denominator[7:4]);
                239: report_byte = hex_ascii(q_denominator[3:0]);
                240: report_byte = " ";
                241: report_byte = "B";
                242: report_byte = "Q";
                243: report_byte = "=";
                244: report_byte = hex_ascii(q_quotient[63:60]);
                245: report_byte = hex_ascii(q_quotient[59:56]);
                246: report_byte = hex_ascii(q_quotient[55:52]);
                247: report_byte = hex_ascii(q_quotient[51:48]);
                248: report_byte = hex_ascii(q_quotient[47:44]);
                249: report_byte = hex_ascii(q_quotient[43:40]);
                250: report_byte = hex_ascii(q_quotient[39:36]);
                251: report_byte = hex_ascii(q_quotient[35:32]);
                252: report_byte = hex_ascii(q_quotient[31:28]);
                253: report_byte = hex_ascii(q_quotient[27:24]);
                254: report_byte = hex_ascii(q_quotient[23:20]);
                255: report_byte = hex_ascii(q_quotient[19:16]);
                256: report_byte = hex_ascii(q_quotient[15:12]);
                257: report_byte = hex_ascii(q_quotient[11:8]);
                258: report_byte = hex_ascii(q_quotient[7:4]);
                259: report_byte = hex_ascii(q_quotient[3:0]);
                260: report_byte = " ";
                261: report_byte = "S";
                262: report_byte = "A";
                263: report_byte = "=";
                264: report_byte = hex_ascii(q0_sum_a[63:60]);
                265: report_byte = hex_ascii(q0_sum_a[59:56]);
                266: report_byte = hex_ascii(q0_sum_a[55:52]);
                267: report_byte = hex_ascii(q0_sum_a[51:48]);
                268: report_byte = hex_ascii(q0_sum_a[47:44]);
                269: report_byte = hex_ascii(q0_sum_a[43:40]);
                270: report_byte = hex_ascii(q0_sum_a[39:36]);
                271: report_byte = hex_ascii(q0_sum_a[35:32]);
                272: report_byte = hex_ascii(q0_sum_a[31:28]);
                273: report_byte = hex_ascii(q0_sum_a[27:24]);
                274: report_byte = hex_ascii(q0_sum_a[23:20]);
                275: report_byte = hex_ascii(q0_sum_a[19:16]);
                276: report_byte = hex_ascii(q0_sum_a[15:12]);
                277: report_byte = hex_ascii(q0_sum_a[11:8]);
                278: report_byte = hex_ascii(q0_sum_a[7:4]);
                279: report_byte = hex_ascii(q0_sum_a[3:0]);
                280: report_byte = " ";
                281: report_byte = "S";
                282: report_byte = "B";
                283: report_byte = "=";
                284: report_byte = hex_ascii(q0_sum_b[63:60]);
                285: report_byte = hex_ascii(q0_sum_b[59:56]);
                286: report_byte = hex_ascii(q0_sum_b[55:52]);
                287: report_byte = hex_ascii(q0_sum_b[51:48]);
                288: report_byte = hex_ascii(q0_sum_b[47:44]);
                289: report_byte = hex_ascii(q0_sum_b[43:40]);
                290: report_byte = hex_ascii(q0_sum_b[39:36]);
                291: report_byte = hex_ascii(q0_sum_b[35:32]);
                292: report_byte = hex_ascii(q0_sum_b[31:28]);
                293: report_byte = hex_ascii(q0_sum_b[27:24]);
                294: report_byte = hex_ascii(q0_sum_b[23:20]);
                295: report_byte = hex_ascii(q0_sum_b[19:16]);
                296: report_byte = hex_ascii(q0_sum_b[15:12]);
                297: report_byte = hex_ascii(q0_sum_b[11:8]);
                298: report_byte = hex_ascii(q0_sum_b[7:4]);
                299: report_byte = hex_ascii(q0_sum_b[3:0]);
                300: report_byte = " ";
                301: report_byte = "Q";
                302: report_byte = "N";
                303: report_byte = "=";
                304: report_byte = hex_ascii(q0_numerator[63:60]);
                305: report_byte = hex_ascii(q0_numerator[59:56]);
                306: report_byte = hex_ascii(q0_numerator[55:52]);
                307: report_byte = hex_ascii(q0_numerator[51:48]);
                308: report_byte = hex_ascii(q0_numerator[47:44]);
                309: report_byte = hex_ascii(q0_numerator[43:40]);
                310: report_byte = hex_ascii(q0_numerator[39:36]);
                311: report_byte = hex_ascii(q0_numerator[35:32]);
                312: report_byte = hex_ascii(q0_numerator[31:28]);
                313: report_byte = hex_ascii(q0_numerator[27:24]);
                314: report_byte = hex_ascii(q0_numerator[23:20]);
                315: report_byte = hex_ascii(q0_numerator[19:16]);
                316: report_byte = hex_ascii(q0_numerator[15:12]);
                317: report_byte = hex_ascii(q0_numerator[11:8]);
                318: report_byte = hex_ascii(q0_numerator[7:4]);
                319: report_byte = hex_ascii(q0_numerator[3:0]);
                320: report_byte = " ";
                321: report_byte = "Q";
                322: report_byte = "D";
                323: report_byte = "=";
                324: report_byte = hex_ascii(q0_denominator[63:60]);
                325: report_byte = hex_ascii(q0_denominator[59:56]);
                326: report_byte = hex_ascii(q0_denominator[55:52]);
                327: report_byte = hex_ascii(q0_denominator[51:48]);
                328: report_byte = hex_ascii(q0_denominator[47:44]);
                329: report_byte = hex_ascii(q0_denominator[43:40]);
                330: report_byte = hex_ascii(q0_denominator[39:36]);
                331: report_byte = hex_ascii(q0_denominator[35:32]);
                332: report_byte = hex_ascii(q0_denominator[31:28]);
                333: report_byte = hex_ascii(q0_denominator[27:24]);
                334: report_byte = hex_ascii(q0_denominator[23:20]);
                335: report_byte = hex_ascii(q0_denominator[19:16]);
                336: report_byte = hex_ascii(q0_denominator[15:12]);
                337: report_byte = hex_ascii(q0_denominator[11:8]);
                338: report_byte = hex_ascii(q0_denominator[7:4]);
                339: report_byte = hex_ascii(q0_denominator[3:0]);
                340: report_byte = " ";
                341: report_byte = "Q";
                342: report_byte = "Q";
                343: report_byte = "=";
                344: report_byte = hex_ascii(q0_quotient[63:60]);
                345: report_byte = hex_ascii(q0_quotient[59:56]);
                346: report_byte = hex_ascii(q0_quotient[55:52]);
                347: report_byte = hex_ascii(q0_quotient[51:48]);
                348: report_byte = hex_ascii(q0_quotient[47:44]);
                349: report_byte = hex_ascii(q0_quotient[43:40]);
                350: report_byte = hex_ascii(q0_quotient[39:36]);
                351: report_byte = hex_ascii(q0_quotient[35:32]);
                352: report_byte = hex_ascii(q0_quotient[31:28]);
                353: report_byte = hex_ascii(q0_quotient[27:24]);
                354: report_byte = hex_ascii(q0_quotient[23:20]);
                355: report_byte = hex_ascii(q0_quotient[19:16]);
                356: report_byte = hex_ascii(q0_quotient[15:12]);
                357: report_byte = hex_ascii(q0_quotient[11:8]);
                358: report_byte = hex_ascii(q0_quotient[7:4]);
                359: report_byte = hex_ascii(q0_quotient[3:0]);
                360: report_byte = " ";
                361: report_byte = "A";
                362: report_byte = "1";
                363: report_byte = "=";
                364: report_byte = hex_ascii(a1[47:44]);
                365: report_byte = hex_ascii(a1[43:40]);
                366: report_byte = hex_ascii(a1[39:36]);
                367: report_byte = hex_ascii(a1[35:32]);
                368: report_byte = hex_ascii(a1[31:28]);
                369: report_byte = hex_ascii(a1[27:24]);
                370: report_byte = hex_ascii(a1[23:20]);
                371: report_byte = hex_ascii(a1[19:16]);
                372: report_byte = hex_ascii(a1[15:12]);
                373: report_byte = hex_ascii(a1[11:8]);
                374: report_byte = hex_ascii(a1[7:4]);
                375: report_byte = hex_ascii(a1[3:0]);
                376: report_byte = " ";
                377: report_byte = "A";
                378: report_byte = "3";
                379: report_byte = "=";
                380: report_byte = hex_ascii(a3[47:44]);
                381: report_byte = hex_ascii(a3[43:40]);
                382: report_byte = hex_ascii(a3[39:36]);
                383: report_byte = hex_ascii(a3[35:32]);
                384: report_byte = hex_ascii(a3[31:28]);
                385: report_byte = hex_ascii(a3[27:24]);
                386: report_byte = hex_ascii(a3[23:20]);
                387: report_byte = hex_ascii(a3[19:16]);
                388: report_byte = hex_ascii(a3[15:12]);
                389: report_byte = hex_ascii(a3[11:8]);
                390: report_byte = hex_ascii(a3[7:4]);
                391: report_byte = hex_ascii(a3[3:0]);
                392: report_byte = " ";
                393: report_byte = "A";
                394: report_byte = "4";
                395: report_byte = "=";
                396: report_byte = hex_ascii(a4[47:44]);
                397: report_byte = hex_ascii(a4[43:40]);
                398: report_byte = hex_ascii(a4[39:36]);
                399: report_byte = hex_ascii(a4[35:32]);
                400: report_byte = hex_ascii(a4[31:28]);
                401: report_byte = hex_ascii(a4[27:24]);
                402: report_byte = hex_ascii(a4[23:20]);
                403: report_byte = hex_ascii(a4[19:16]);
                404: report_byte = hex_ascii(a4[15:12]);
                405: report_byte = hex_ascii(a4[11:8]);
                406: report_byte = hex_ascii(a4[7:4]);
                407: report_byte = hex_ascii(a4[3:0]);
                408: report_byte = " ";
                409: report_byte = "B";
                410: report_byte = "1";
                411: report_byte = "=";
                412: report_byte = hex_ascii(b1[47:44]);
                413: report_byte = hex_ascii(b1[43:40]);
                414: report_byte = hex_ascii(b1[39:36]);
                415: report_byte = hex_ascii(b1[35:32]);
                416: report_byte = hex_ascii(b1[31:28]);
                417: report_byte = hex_ascii(b1[27:24]);
                418: report_byte = hex_ascii(b1[23:20]);
                419: report_byte = hex_ascii(b1[19:16]);
                420: report_byte = hex_ascii(b1[15:12]);
                421: report_byte = hex_ascii(b1[11:8]);
                422: report_byte = hex_ascii(b1[7:4]);
                423: report_byte = hex_ascii(b1[3:0]);
                424: report_byte = " ";
                425: report_byte = "B";
                426: report_byte = "3";
                427: report_byte = "=";
                428: report_byte = hex_ascii(b3[47:44]);
                429: report_byte = hex_ascii(b3[43:40]);
                430: report_byte = hex_ascii(b3[39:36]);
                431: report_byte = hex_ascii(b3[35:32]);
                432: report_byte = hex_ascii(b3[31:28]);
                433: report_byte = hex_ascii(b3[27:24]);
                434: report_byte = hex_ascii(b3[23:20]);
                435: report_byte = hex_ascii(b3[19:16]);
                436: report_byte = hex_ascii(b3[15:12]);
                437: report_byte = hex_ascii(b3[11:8]);
                438: report_byte = hex_ascii(b3[7:4]);
                439: report_byte = hex_ascii(b3[3:0]);
                440: report_byte = " ";
                441: report_byte = "B";
                442: report_byte = "4";
                443: report_byte = "=";
                444: report_byte = hex_ascii(b4[47:44]);
                445: report_byte = hex_ascii(b4[43:40]);
                446: report_byte = hex_ascii(b4[39:36]);
                447: report_byte = hex_ascii(b4[35:32]);
                448: report_byte = hex_ascii(b4[31:28]);
                449: report_byte = hex_ascii(b4[27:24]);
                450: report_byte = hex_ascii(b4[23:20]);
                451: report_byte = hex_ascii(b4[19:16]);
                452: report_byte = hex_ascii(b4[15:12]);
                453: report_byte = hex_ascii(b4[11:8]);
                454: report_byte = hex_ascii(b4[7:4]);
                455: report_byte = hex_ascii(b4[3:0]);
                456: report_byte = " ";
                457: report_byte = "S";
                458: report_byte = "I";
                459: report_byte = "3";
                460: report_byte = "=";
                461: report_byte = hex_ascii(sum_i3[31:28]);
                462: report_byte = hex_ascii(sum_i3[27:24]);
                463: report_byte = hex_ascii(sum_i3[23:20]);
                464: report_byte = hex_ascii(sum_i3[19:16]);
                465: report_byte = hex_ascii(sum_i3[15:12]);
                466: report_byte = hex_ascii(sum_i3[11:8]);
                467: report_byte = hex_ascii(sum_i3[7:4]);
                468: report_byte = hex_ascii(sum_i3[3:0]);
                469: report_byte = " ";
                470: report_byte = "S";
                471: report_byte = "P";
                472: report_byte = "3";
                473: report_byte = "=";
                474: report_byte = hex_ascii(sum_p3[31:28]);
                475: report_byte = hex_ascii(sum_p3[27:24]);
                476: report_byte = hex_ascii(sum_p3[23:20]);
                477: report_byte = hex_ascii(sum_p3[19:16]);
                478: report_byte = hex_ascii(sum_p3[15:12]);
                479: report_byte = hex_ascii(sum_p3[11:8]);
                480: report_byte = hex_ascii(sum_p3[7:4]);
                481: report_byte = hex_ascii(sum_p3[3:0]);
                482: report_byte = " ";
                483: report_byte = "S";
                484: report_byte = "I";
                485: report_byte = "I";
                486: report_byte = "3";
                487: report_byte = "=";
                488: report_byte = hex_ascii(sum_ii3[31:28]);
                489: report_byte = hex_ascii(sum_ii3[27:24]);
                490: report_byte = hex_ascii(sum_ii3[23:20]);
                491: report_byte = hex_ascii(sum_ii3[19:16]);
                492: report_byte = hex_ascii(sum_ii3[15:12]);
                493: report_byte = hex_ascii(sum_ii3[11:8]);
                494: report_byte = hex_ascii(sum_ii3[7:4]);
                495: report_byte = hex_ascii(sum_ii3[3:0]);
                496: report_byte = " ";
                497: report_byte = "S";
                498: report_byte = "I";
                499: report_byte = "P";
                500: report_byte = "3";
                501: report_byte = "=";
                502: report_byte = hex_ascii(sum_ip3[31:28]);
                503: report_byte = hex_ascii(sum_ip3[27:24]);
                504: report_byte = hex_ascii(sum_ip3[23:20]);
                505: report_byte = hex_ascii(sum_ip3[19:16]);
                506: report_byte = hex_ascii(sum_ip3[15:12]);
                507: report_byte = hex_ascii(sum_ip3[11:8]);
                508: report_byte = hex_ascii(sum_ip3[7:4]);
                509: report_byte = hex_ascii(sum_ip3[3:0]);
                510: report_byte = " ";
                511: report_byte = "S";
                512: report_byte = "I";
                513: report_byte = "4";
                514: report_byte = "=";
                515: report_byte = hex_ascii(sum_i4[31:28]);
                516: report_byte = hex_ascii(sum_i4[27:24]);
                517: report_byte = hex_ascii(sum_i4[23:20]);
                518: report_byte = hex_ascii(sum_i4[19:16]);
                519: report_byte = hex_ascii(sum_i4[15:12]);
                520: report_byte = hex_ascii(sum_i4[11:8]);
                521: report_byte = hex_ascii(sum_i4[7:4]);
                522: report_byte = hex_ascii(sum_i4[3:0]);
                523: report_byte = " ";
                524: report_byte = "S";
                525: report_byte = "P";
                526: report_byte = "4";
                527: report_byte = "=";
                528: report_byte = hex_ascii(sum_p4[31:28]);
                529: report_byte = hex_ascii(sum_p4[27:24]);
                530: report_byte = hex_ascii(sum_p4[23:20]);
                531: report_byte = hex_ascii(sum_p4[19:16]);
                532: report_byte = hex_ascii(sum_p4[15:12]);
                533: report_byte = hex_ascii(sum_p4[11:8]);
                534: report_byte = hex_ascii(sum_p4[7:4]);
                535: report_byte = hex_ascii(sum_p4[3:0]);
                536: report_byte = " ";
                537: report_byte = "S";
                538: report_byte = "I";
                539: report_byte = "I";
                540: report_byte = "4";
                541: report_byte = "=";
                542: report_byte = hex_ascii(sum_ii4[31:28]);
                543: report_byte = hex_ascii(sum_ii4[27:24]);
                544: report_byte = hex_ascii(sum_ii4[23:20]);
                545: report_byte = hex_ascii(sum_ii4[19:16]);
                546: report_byte = hex_ascii(sum_ii4[15:12]);
                547: report_byte = hex_ascii(sum_ii4[11:8]);
                548: report_byte = hex_ascii(sum_ii4[7:4]);
                549: report_byte = hex_ascii(sum_ii4[3:0]);
                550: report_byte = " ";
                551: report_byte = "S";
                552: report_byte = "I";
                553: report_byte = "P";
                554: report_byte = "4";
                555: report_byte = "=";
                556: report_byte = hex_ascii(sum_ip4[31:28]);
                557: report_byte = hex_ascii(sum_ip4[27:24]);
                558: report_byte = hex_ascii(sum_ip4[23:20]);
                559: report_byte = hex_ascii(sum_ip4[19:16]);
                560: report_byte = hex_ascii(sum_ip4[15:12]);
                561: report_byte = hex_ascii(sum_ip4[11:8]);
                562: report_byte = hex_ascii(sum_ip4[7:4]);
                563: report_byte = hex_ascii(sum_ip4[3:0]);
                564: report_byte = 8'h0d;
                default: report_byte = 8'h0a;
            endcase
        end
    endfunction

    reg tx_busy;
    reg [9:0] tx_shift;
    reg [3:0] tx_bit;
    reg [15:0] tx_timer;
    reg [9:0] report_index;
    wire [31:0] digest_next =
        {output_digest[26:0], output_digest[31:27]} ^ {16'd0, m_t};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_COMMAND;
            input_index <= 0;
            output_index <= 0;
            output_digest <= 0;
            failed <= 0;
            passed <= 0;
            error_code <= 0;
            mismatch_seen <= 0;
            mismatch_index <= 0;
            mismatch_pixel <= 0;
            first_quotient <= 0;
            first_a_value <= 0;
            first_b_value <= 0;
            first_sum_i <= 0;
            first_sum_p <= 0;
            first_sum_ii <= 0;
            first_sum_ip <= 0;
            frame_error_flags <= 0;
            first_a_numerator <= 0;
            first_a_denominator <= 0;
            first_b_numerator <= 0;
            first_b_denominator <= 0;
            second_q_numerator <= 0;
            second_q_denominator <= 0;
            second_q_quotient <= 0;
            first_q_sum_a <= 0;
            first_q_sum_b <= 0;
            first_q_numerator <= 0;
            first_q_denominator <= 0;
            a_coeff_1 <= 0;
            a_coeff_3 <= 0;
            a_coeff_4 <= 0;
            b_coeff_1 <= 0;
            b_coeff_3 <= 0;
            b_coeff_4 <= 0;
            a3_sum_i <= 0;
            a3_sum_p <= 0;
            a3_sum_ii <= 0;
            a3_sum_ip <= 0;
            a4_sum_i <= 0;
            a4_sum_p <= 0;
            a4_sum_ii <= 0;
            a4_sum_ip <= 0;
            watchdog <= 0;
            tx_busy <= 0;
            tx_shift <= 10'h3ff;
            tx_bit <= 0;
            tx_timer <= 0;
            report_index <= 0;
            uart_tx <= 1'b1;
        end else if (state != ST_DONE && state != ST_REPORT &&
                     watchdog == 24'd5000000) begin
            failed <= 1'b1;
            error_code <= 8'hff;
            state <= ST_REPORT;
            report_index <= 0;
            tx_busy <= 0;
            uart_tx <= 1'b1;
        end else begin
            if (state != ST_DONE && state != ST_REPORT)
                watchdog <= watchdog + 1'b1;
            // Snapshot the very first B-divider completion, before later
            // output-filter divisions reuse this shared arithmetic unit.
            if (guided_refine_i.state == 5'd16 &&
                guided_refine_i.index == 0 && guided_refine_i.divide_done) begin
                second_q_numerator <= guided_refine_i.u_divider.quotient_magnitude;
                second_q_denominator <= guided_refine_i.u_divider.remainder[63:0];
                second_q_quotient <= guided_refine_i.u_divider.quotient;
            end
            case (state)
                ST_COMMAND: if (cmd_ready) begin
                    input_index <= 0;
                    state <= ST_INPUT;
                end
                ST_INPUT: if (s_valid && s_ready) begin
                    if (input_index == FRAME_PIXELS-1) begin
                        output_index <= 0;
                        state <= ST_OUTPUT;
                    end else input_index <= input_index + 1'b1;
                end
                ST_OUTPUT: if (m_valid && m_ready) begin
                    if (output_index == 0) begin
                        first_quotient <= debug_divide_quotient;
                        first_a_value <= debug_first_a_value;
                        first_b_value <= debug_first_b_value;
                        first_sum_i <= debug_first_sum_i;
                        first_sum_p <= debug_first_sum_p;
                        first_sum_ii <= debug_first_sum_ii;
                        first_sum_ip <= debug_first_sum_ip;
                        frame_error_flags <= debug_frame_error_flags;
                        first_a_numerator <= debug_first_a_numerator;
                        first_a_denominator <= debug_first_a_denominator;
                        first_b_numerator <= debug_first_b_numerator;
                        first_b_denominator <= debug_first_b_denominator;
                        first_q_sum_a <= debug_first_q_sum_a;
                        first_q_sum_b <= debug_first_q_sum_b;
                        first_q_numerator <= debug_first_q_numerator;
                        first_q_denominator <= debug_first_q_denominator;
                        a_coeff_1 <= debug_a_coeff_1;
                        a_coeff_3 <= debug_a_coeff_3;
                        a_coeff_4 <= debug_a_coeff_4;
                        b_coeff_1 <= debug_b_coeff_1;
                        b_coeff_3 <= debug_b_coeff_3;
                        b_coeff_4 <= debug_b_coeff_4;
                        a3_sum_i <= debug_a3_sum_i;
                        a3_sum_p <= debug_a3_sum_p;
                        a3_sum_ii <= debug_a3_sum_ii;
                        a3_sum_ip <= debug_a3_sum_ip;
                        a4_sum_i <= debug_a4_sum_i;
                        a4_sum_p <= debug_a4_sum_p;
                        a4_sum_ii <= debug_a4_sum_ii;
                        a4_sum_ip <= debug_a4_sum_ip;
                    end
                    if (m_t !== golden_pixel(output_index) ||
                        m_sof !== (output_index == 0) ||
                        m_eol !== ((output_index == 2) || (output_index == 5)) ||
                        m_eof !== (output_index == FRAME_PIXELS-1)) begin
                        failed <= 1'b1;
                        error_code <= 8'h01;
                        if (!mismatch_seen) begin
                            mismatch_seen <= 1'b1;
                            mismatch_index <= output_index;
                            mismatch_pixel <= m_t;
                        end
                    end
                    output_digest <= digest_next;
                    if (output_index == FRAME_PIXELS-1) begin
                        if (digest_next !== GOLDEN_DIGEST) begin
                            failed <= 1'b1;
                            error_code <= 8'h02;
                        end
                        state <= ST_RESPONSE;
                    end else output_index <= output_index + 1'b1;
                end
                ST_RESPONSE: if (rsp_valid) begin
                    if (rsp_error != 0) begin
                        failed <= 1'b1;
                        error_code <= {4'd0, rsp_error};
                    end else if (!failed && output_digest == GOLDEN_DIGEST) begin
                        passed <= 1'b1;
                    end
                    state <= ST_REPORT;
                    report_index <= 0;
                end
                ST_REPORT: begin
                    if (!tx_busy) begin
                        if (report_index == REPORT_LENGTH) state <= ST_DONE;
                        else begin
                            tx_shift <= {1'b1,
                                report_byte(report_index, failed, output_digest, error_code,
                                            mismatch_index, mismatch_pixel, first_quotient,
                                            first_a_value, first_b_value, first_sum_i,
                                            first_sum_p, first_sum_ii, first_sum_ip,
                                            frame_error_flags, first_a_numerator,
                                            first_a_denominator, first_b_numerator,
                                            first_b_denominator, second_q_numerator,
                                            second_q_denominator, second_q_quotient,
                                            first_q_sum_a, first_q_sum_b, first_q_numerator,
                                            first_q_denominator, first_quotient,
                                            a_coeff_1, a_coeff_3, a_coeff_4,
                                            b_coeff_1, b_coeff_3, b_coeff_4,
                                            a3_sum_i, a3_sum_p, a3_sum_ii, a3_sum_ip,
                                            a4_sum_i, a4_sum_p, a4_sum_ii, a4_sum_ip),
                                1'b0};
                            tx_bit <= 0;
                            tx_timer <= BAUD_DIV - 1;
                            tx_busy <= 1'b1;
                            uart_tx <= 1'b0;
                        end
                    end else if (tx_timer != 0) begin
                        tx_timer <= tx_timer - 1'b1;
                    end else if (tx_bit == 9) begin
                        tx_busy <= 1'b0;
                        uart_tx <= 1'b1;
                        report_index <= report_index + 1'b1;
                    end else begin
                        tx_shift <= {1'b1, tx_shift[9:1]};
                        uart_tx <= tx_shift[1];
                        tx_bit <= tx_bit + 1'b1;
                        tx_timer <= BAUD_DIV - 1;
                    end
                end
                default: begin end
            endcase
        end
    end

    // This input is retained only to match the shared Tang25K CST pinout; the
    // self-test is autonomous and does not consume host commands.
    wire unused_uart_rx = uart_rx_pin;
endmodule

`default_nettype wire
