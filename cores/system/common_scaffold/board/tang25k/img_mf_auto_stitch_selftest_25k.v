`default_nettype none

// Board-visible end-to-end auto-stitch regression for the Tang Primer 25K.
// Two fixed 6x5 RGB frames differ by a one-pixel horizontal translation. The
// harness checks the detected translation and every pixel/marker of the 8x7
// stitched canvas before sending exactly one UART line: STITCH PASS or FAIL.
module img_mf_auto_stitch_selftest_25k #(
    parameter integer CLK_HZ = 25000000,
    parameter integer BAUD = 115200,
    parameter integer POR_CYCLES = 32768
) (
    input wire clk,
    input wire uart_rx_pin,
    output reg uart_tx,
    output wire dbg_uart
);
    localparam integer WIDTH = 6;
    localparam integer HEIGHT = 5;
    localparam integer MAX_SHIFT = 1;
    localparam integer CANVAS_WIDTH = WIDTH + 2*MAX_SHIFT;
    localparam integer CANVAS_HEIGHT = HEIGHT + 2*MAX_SHIFT;
    localparam integer PIXELS = WIDTH*HEIGHT;
    localparam integer CANVAS_PIXELS = CANVAS_WIDTH*CANVAS_HEIGHT;
    localparam integer BAUD_DIV = CLK_HZ / BAUD;
    localparam [3:0] ST_CAPTURE_CMD = 0, ST_CAPTURE_FEED = 1,
                     ST_CAPTURE_RSP = 2, ST_STITCH_CMD = 3,
                     ST_STITCH_OUT = 4, ST_STITCH_RSP = 5,
                     ST_REPORT = 6, ST_DONE = 7;
    localparam integer REPORT_LENGTH = 13;
    localparam [20:0] WATCHDOG_LIMIT = 21'd1000000;

    localparam integer POR_WIDTH = (POR_CYCLES < 2) ? 1 : $clog2(POR_CYCLES+1);
    reg [POR_WIDTH-1:0] por_count = {POR_WIDTH{1'b0}};
    always @(posedge clk) begin
        if (por_count < POR_CYCLES) por_count <= por_count + 1'b1;
    end
    // E2 is a 50 MHz source. The GW5A PLLA generates a 25 MHz functional clock
    // on its dedicated global clock output. The divider primitive previously
    // used here could not be routed reliably by the available GW5A P&R flow.
    // Keep POR on the 50 MHz source; release the functional reset only after
    // both the POR interval has elapsed and PLLA reports a stable lock.
    wire functional_clk;
    wire pll_lock;
    wire [7:0] pll_mdrdo;
    PLLA #(
        .FCLKIN("50.0"),
        .IDIV_SEL(1), .FBDIV_SEL(1), .MDIV_SEL(16),
        .ODIV0_SEL(32),
        .ODIV1_SEL(8), .ODIV2_SEL(8), .ODIV3_SEL(8),
        .ODIV4_SEL(8), .ODIV5_SEL(8), .ODIV6_SEL(8),
        .CLKOUT0_EN("TRUE"),
        .CLKOUT1_EN("FALSE"), .CLKOUT2_EN("FALSE"),
        .CLKOUT3_EN("FALSE"), .CLKOUT4_EN("FALSE"),
        .CLKOUT5_EN("FALSE"), .CLKOUT6_EN("FALSE"),
        .CLKFB_SEL("INTERNAL")
    ) functional_clock_pll (
        .CLKIN(clk), .CLKFB(1'b0),
        .RESET(1'b0), .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0),
        .PSSEL(3'b000), .PSDIR(1'b0), .PSPULSE(1'b0),
        .SSCPOL(1'b0), .SSCON(1'b0), .SSCMDSEL(7'b0000000),
        .SSCMDSEL_FRAC(3'b000), .MDCLK(1'b0), .MDOPC(2'b00),
        .MDAINC(1'b0), .MDWDI(8'b00000000), .MDRDO(pll_mdrdo),
        .LOCK(pll_lock), .CLKOUT0(functional_clk), .CLKOUT1(),
        .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT()
    );
    wire por_done = por_count >= POR_CYCLES;
    wire rst_n = por_done && pll_lock;

    reg [3:0] state;
    reg [4:0] input_index;
    reg [5:0] output_index;
    reg [20:0] watchdog;
    reg failed, passed;
    reg tx_busy;
    reg [9:0] tx_shift;
    reg [3:0] tx_bit;
    reg [15:0] tx_timer;
    reg [3:0] report_index;

    wire cmd_valid = (state == ST_CAPTURE_CMD) || (state == ST_STITCH_CMD);
    wire cmd_ready;
    wire [3:0] cmd_opcode = (state == ST_CAPTURE_CMD) ? 4'd2 : 4'd3;
    wire [15:0] cmd_frameid = (state == ST_CAPTURE_CMD) ? 16'd1 : 16'd2;
    wire rsp_valid;
    wire [3:0] rsp_opcode;
    wire [15:0] rsp_frameid;
    wire [7:0] rsp_error;
    wire [7:0] error_code;
    wire [1:0] frames_valid;
    wire signed [15:0] registration_dx, registration_dy;
    wire [47:0] registration_cost, registration_confidence;
    wire [31:0] canvas_width, canvas_height;
    wire s_valid = state == ST_CAPTURE_FEED;
    wire s_ready, aux_ready;
    wire [23:0] s_data = main_pixel(input_index);
    wire [23:0] aux_data = auxiliary_pixel(input_index);
    wire s_sof = input_index == 0;
    wire s_eol = input_eol(input_index);
    wire [15:0] s_tag = {11'd0,input_index};
    wire [15:0] s_frameid = 16'd1;
    wire aux_sof = s_sof;
    wire aux_eol = s_eol;
    wire [15:0] aux_tag = s_tag;
    wire [15:0] aux_frameid = s_frameid;
    wire m_valid;
    wire m_ready = state == ST_STITCH_OUT;
    wire [23:0] m_data;
    wire m_sof, m_eol;
    wire [15:0] m_tag, m_frameid;
    wire [7:0] m_error;
    wire rsp_ready = 1'b1;

    img_mf_auto_stitch #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .MAX_SHIFT(MAX_SHIFT),
        .TAG_WIDTH(16), .FRAME_WIDTH(16), .CAPTURE_TIMEOUT(4096),
        .MIN_CONFIDENCE(1)
    ) dut (
        .clk(functional_clk), .rst_n(rst_n), .clk_en(1'b1),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_opcode(cmd_opcode),
        .cmd_frameid(cmd_frameid), .cfg_aux_weight(9'd128),
        .cfg_background(24'h030303),
        .cfg_h00(32'sd1), .cfg_h01(32'sd0), .cfg_h02(32'sd0),
        .cfg_h10(32'sd0), .cfg_h11(32'sd1), .cfg_h12(32'sd0),
        .cfg_h20(32'sd0), .cfg_h21(32'sd0), .cfg_h22(32'sd1),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_done(),
        .rsp_opcode(rsp_opcode), .rsp_frameid(rsp_frameid),
        .rsp_error(rsp_error), .error_code(error_code),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .s_sof(s_sof), .s_eol(s_eol), .s_tag(s_tag), .s_frameid(s_frameid),
        .aux_valid(s_valid), .aux_ready(aux_ready), .aux_data(aux_data),
        .aux_sof(aux_sof), .aux_eol(aux_eol), .aux_tag(aux_tag),
        .aux_frameid(aux_frameid),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data),
        .m_sof(m_sof), .m_eol(m_eol), .m_tag(m_tag),
        .m_frameid(m_frameid), .m_error(m_error),
        .frames_valid(frames_valid), .registration_dx(registration_dx),
        .registration_dy(registration_dy), .registration_cost(registration_cost),
        .registration_confidence(registration_confidence),
        .canvas_width(canvas_width), .canvas_height(canvas_height)
    );

    // Fixed test frame. The auxiliary frame is main(x-1,y), with a sentinel
    // at its left edge, so the expected SAD registration is dx=+1, dy=0.
    function [23:0] main_pixel;
        input [4:0] index;
        begin
            case (index)
                 0: main_pixel=24'h1e1e1e;  1: main_pixel=24'h656565;
                 2: main_pixel=24'hacacac;  3: main_pixel=24'h3f3f3f;
                 4: main_pixel=24'h868686;  5: main_pixel=24'hcdcdcd;
                 6: main_pixel=24'h494949;  7: main_pixel=24'ha3a3a3;
                 8: main_pixel=24'h494949;  9: main_pixel=24'ha3a3a3;
                10: main_pixel=24'h494949; 11: main_pixel=24'ha3a3a3;
                12: main_pixel=24'h747474; 13: main_pixel=24'h2d2d2d;
                14: main_pixel=24'h9a9a9a; 15: main_pixel=24'h535353;
                16: main_pixel=24'hc0c0c0; 17: main_pixel=24'h797979;
                18: main_pixel=24'h9f9f9f; 19: main_pixel=24'h6b6b6b;
                20: main_pixel=24'h373737; 21: main_pixel=24'hb7b7b7;
                22: main_pixel=24'h838383; 23: main_pixel=24'h4f4f4f;
                24: main_pixel=24'hcacaca; 25: main_pixel=24'ha9a9a9;
                26: main_pixel=24'h888888; 27: main_pixel=24'h676767;
                28: main_pixel=24'h464646; 29: main_pixel=24'h252525;
                default: main_pixel=24'd0;
            endcase
        end
    endfunction

    function [23:0] auxiliary_pixel;
        input [4:0] index;
        begin
            case (index)
                 0: auxiliary_pixel=24'h111111;  1: auxiliary_pixel=24'h1e1e1e;
                 2: auxiliary_pixel=24'h656565;  3: auxiliary_pixel=24'hacacac;
                 4: auxiliary_pixel=24'h3f3f3f;  5: auxiliary_pixel=24'h868686;
                 6: auxiliary_pixel=24'h111111;  7: auxiliary_pixel=24'h494949;
                 8: auxiliary_pixel=24'ha3a3a3;  9: auxiliary_pixel=24'h494949;
                10: auxiliary_pixel=24'ha3a3a3; 11: auxiliary_pixel=24'h494949;
                12: auxiliary_pixel=24'h111111; 13: auxiliary_pixel=24'h747474;
                14: auxiliary_pixel=24'h2d2d2d; 15: auxiliary_pixel=24'h9a9a9a;
                16: auxiliary_pixel=24'h535353; 17: auxiliary_pixel=24'hc0c0c0;
                18: auxiliary_pixel=24'h111111; 19: auxiliary_pixel=24'h9f9f9f;
                20: auxiliary_pixel=24'h6b6b6b; 21: auxiliary_pixel=24'h373737;
                22: auxiliary_pixel=24'hb7b7b7; 23: auxiliary_pixel=24'h838383;
                24: auxiliary_pixel=24'h111111; 25: auxiliary_pixel=24'hcacaca;
                26: auxiliary_pixel=24'ha9a9a9; 27: auxiliary_pixel=24'h888888;
                28: auxiliary_pixel=24'h676767; 29: auxiliary_pixel=24'h464646;
                default: auxiliary_pixel=24'd0;
            endcase
        end
    endfunction

    function input_eol;
        input [4:0] index;
        begin
            input_eol = (index==5 || index==11 || index==17 ||
                         index==23 || index==29);
        end
    endfunction

    // Golden RGB pixels for the 8x7 canvas, row-major. This table includes
    // the two one-pixel borders and the 50/50 blend at every overlap pixel.
    function [23:0] expected_pixel;
        input [5:0] index;
        begin
            case (index)
                 0: expected_pixel=24'h030303;  1: expected_pixel=24'h030303;
                 2: expected_pixel=24'h030303;  3: expected_pixel=24'h030303;
                 4: expected_pixel=24'h030303;  5: expected_pixel=24'h030303;
                 6: expected_pixel=24'h030303;  7: expected_pixel=24'h030303;
                 8: expected_pixel=24'h111111;  9: expected_pixel=24'h1e1e1e;
                10: expected_pixel=24'h656565; 11: expected_pixel=24'hacacac;
                12: expected_pixel=24'h3f3f3f; 13: expected_pixel=24'h868686;
                14: expected_pixel=24'hcdcdcd; 15: expected_pixel=24'h030303;
                16: expected_pixel=24'h111111; 17: expected_pixel=24'h494949;
                18: expected_pixel=24'ha3a3a3; 19: expected_pixel=24'h494949;
                20: expected_pixel=24'ha3a3a3; 21: expected_pixel=24'h494949;
                22: expected_pixel=24'ha3a3a3; 23: expected_pixel=24'h030303;
                24: expected_pixel=24'h111111; 25: expected_pixel=24'h747474;
                26: expected_pixel=24'h2d2d2d; 27: expected_pixel=24'h9a9a9a;
                28: expected_pixel=24'h535353; 29: expected_pixel=24'hc0c0c0;
                30: expected_pixel=24'h797979; 31: expected_pixel=24'h030303;
                32: expected_pixel=24'h111111; 33: expected_pixel=24'h9f9f9f;
                34: expected_pixel=24'h6b6b6b; 35: expected_pixel=24'h373737;
                36: expected_pixel=24'hb7b7b7; 37: expected_pixel=24'h838383;
                38: expected_pixel=24'h4f4f4f; 39: expected_pixel=24'h030303;
                40: expected_pixel=24'h111111; 41: expected_pixel=24'hcacaca;
                42: expected_pixel=24'ha9a9a9; 43: expected_pixel=24'h888888;
                44: expected_pixel=24'h676767; 45: expected_pixel=24'h464646;
                46: expected_pixel=24'h252525; 47: expected_pixel=24'h030303;
                48: expected_pixel=24'h030303; 49: expected_pixel=24'h030303;
                50: expected_pixel=24'h030303; 51: expected_pixel=24'h030303;
                52: expected_pixel=24'h030303; 53: expected_pixel=24'h030303;
                54: expected_pixel=24'h030303; 55: expected_pixel=24'h030303;
                default: expected_pixel=24'd0;
            endcase
        end
    endfunction

    function [7:0] report_byte;
        input [3:0] index;
        input is_fail;
        begin
            case (index)
                 0: report_byte="S"; 1: report_byte="T";
                 2: report_byte="I"; 3: report_byte="T";
                 4: report_byte="C"; 5: report_byte="H";
                 6: report_byte=" ";
                 7: report_byte=is_fail?"F":"P";
                 8: report_byte="A";
                 9: report_byte=is_fail?"I":"S";
                10: report_byte=is_fail?"L":"S";
                11: report_byte=8'h0d;
                default: report_byte=8'h0a;
            endcase
        end
    endfunction

    assign dbg_uart = passed;

    always @(posedge functional_clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=ST_CAPTURE_CMD; input_index<=0; output_index<=0;
            watchdog<=0; failed<=0; passed<=0;
            tx_busy<=0; tx_shift<=10'h3ff; tx_bit<=0; tx_timer<=0;
            report_index<=0; uart_tx<=1'b1;
        end else if (state!=ST_REPORT && state!=ST_DONE &&
                     watchdog==WATCHDOG_LIMIT-1'b1) begin
            watchdog<=WATCHDOG_LIMIT;
            failed<=1'b1; state<=ST_REPORT; report_index<=0;
        end else begin
            if (state!=ST_REPORT && state!=ST_DONE) watchdog<=watchdog+1'b1;
            case (state)
                ST_CAPTURE_CMD: if (cmd_valid && cmd_ready) begin
                    input_index<=0; state<=ST_CAPTURE_FEED;
                end
                ST_CAPTURE_FEED: if (s_valid && s_ready && aux_ready) begin
                    if (input_index==PIXELS-1) state<=ST_CAPTURE_RSP;
                    else input_index<=input_index+1'b1;
                end
                ST_CAPTURE_RSP: if (rsp_valid) begin
                    if (rsp_error!=0 || rsp_opcode!=4'd2 || rsp_frameid!=16'd1 ||
                        frames_valid!=2'b11) begin
                        failed<=1'b1; state<=ST_REPORT; report_index<=0;
                    end else state<=ST_STITCH_CMD;
                end
                ST_STITCH_CMD: if (cmd_valid && cmd_ready) begin
                    output_index<=0; state<=ST_STITCH_OUT;
                end
                ST_STITCH_OUT: begin
                    if (rsp_valid && rsp_error!=0) begin
                        failed<=1'b1; state<=ST_REPORT; report_index<=0;
                    end else if (m_valid && m_ready) begin
                        if (m_data!==expected_pixel(output_index) ||
                            m_sof!==(output_index==0) ||
                            m_eol!==(output_index[2:0]==3'd7) ||
                            m_tag!={10'd0,output_index} || m_frameid!=16'd2 ||
                            m_error!=0) begin
                            failed<=1'b1; state<=ST_REPORT; report_index<=0;
                        end else if (output_index==CANVAS_PIXELS-1) begin
                            state<=ST_STITCH_RSP;
                        end else output_index<=output_index+1'b1;
                    end
                end
                ST_STITCH_RSP: if (rsp_valid) begin
                    if (rsp_error!=0 || rsp_opcode!=4'd3 || rsp_frameid!=16'd2 ||
                        registration_dx!=16'sd1 || registration_dy!=16'sd0 ||
                        registration_cost!=0 || registration_confidence==0 ||
                        canvas_width!=CANVAS_WIDTH || canvas_height!=CANVAS_HEIGHT) begin
                        failed<=1'b1;
                    end
                    state<=ST_REPORT; report_index<=0;
                end
                ST_REPORT: begin
                    if (!tx_busy) begin
                        if (report_index==REPORT_LENGTH) begin
                            passed<=!failed; state<=ST_DONE;
                        end else begin
                            tx_shift<={1'b1,report_byte(report_index,failed),1'b0};
                            tx_bit<=0; tx_timer<=BAUD_DIV-1;
                            tx_busy<=1'b1; uart_tx<=1'b0;
                        end
                    end else if (tx_timer!=0) begin
                        tx_timer<=tx_timer-1'b1;
                    end else if (tx_bit==9) begin
                        tx_busy<=1'b0; uart_tx<=1'b1;
                        report_index<=report_index+1'b1;
                    end else begin
                        tx_shift<={1'b1,tx_shift[9:1]};
                        uart_tx<=tx_shift[1]; tx_bit<=tx_bit+1'b1;
                        tx_timer<=BAUD_DIV-1;
                    end
                end
                ST_DONE: begin end
                default: begin
                    failed<=1'b1; state<=ST_REPORT; report_index<=0;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
