`default_nettype none

// Board-visible functional consistency test for the repaired synchronous
// frame filter. It runs a fixed 4x4 grayscale opening, checks every output
// pixel and frame marker against a golden vector, then reports the output
// digest over the Tang Primer 25K USB-UART.
module image_filter_selftest_25k #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input  wire clk,
    input  wire uart_rx_pin,
    output reg  uart_tx,
    output wire dbg_uart
);
    localparam integer BAUD_DIV = CLK_HZ / BAUD;
    localparam [3:0] ST_COMMAND = 0, ST_INPUT = 1, ST_OUTPUT = 2,
                     ST_RESPONSE = 3, ST_REPORT = 4, ST_DONE = 5;
    localparam integer REPORT_LENGTH = 24;
    localparam integer PIXEL_WIDTH = 8;

    reg [15:0] por_count = 16'd0;
    always @(posedge clk) begin
        if (!por_count[15]) por_count <= por_count + 16'd1;
    end
    wire rst_n = por_count[15];

    reg [3:0] state;
    reg [4:0] input_index, output_index;
    reg [31:0] output_digest;
    reg failed, passed;
    reg [7:0] error_code;

    wire cmd_ready, rsp_valid;
    wire [7:0] rsp_tag, rsp_error;
    wire [PIXEL_WIDTH-1:0] m_data;
    wire m_valid, m_sof, m_eol;
    wire s_ready, rsp_ready;

    function [7:0] input_pixel;
        input [4:0] index;
        begin
            case (index)
                0: input_pixel = 8'd9;
                1: input_pixel = 8'd8;
                2: input_pixel = 8'd6;
                3: input_pixel = 8'd4;
                4: input_pixel = 8'd7;
                5: input_pixel = 8'd255;
                6: input_pixel = 8'd5;
                7: input_pixel = 8'd3;
                8: input_pixel = 8'd6;
                9: input_pixel = 8'd4;
                10: input_pixel = 8'd2;
                11: input_pixel = 8'd1;
                12: input_pixel = 8'd8;
                13: input_pixel = 8'd7;
                14: input_pixel = 8'd3;
                default: input_pixel = 8'd0;
            endcase
        end
    endfunction

    function [7:0] expected_pixel;
        input [4:0] index;
        begin
            case (index)
                0: expected_pixel = 8'd7;
                1: expected_pixel = 8'd7;
                2: expected_pixel = 8'd5;
                3: expected_pixel = 8'd3;
                4: expected_pixel = 8'd7;
                5: expected_pixel = 8'd7;
                6: expected_pixel = 8'd5;
                7: expected_pixel = 8'd3;
                8: expected_pixel = 8'd4;
                9: expected_pixel = 8'd4;
                10: expected_pixel = 8'd2;
                11: expected_pixel = 8'd1;
                12: expected_pixel = 8'd4;
                13: expected_pixel = 8'd4;
                14: expected_pixel = 8'd2;
                default: expected_pixel = 8'd0;
            endcase
        end
    endfunction

    wire s_valid = state == ST_INPUT;
    wire [7:0] s_data = input_pixel(input_index);
    wire s_sof = input_index == 0;
    wire s_eol = input_index[1:0] == 2'b11;
    wire m_ready = state == ST_OUTPUT;
    assign rsp_ready = state == ST_RESPONSE;

    img_filter_frame_engine #(
        .PIXEL_W(8), .MAX_WIDTH(4), .MAX_HEIGHT(4), .OP(0),
        .MAX_PATCH_RADIUS(1), .MAX_SEARCH_RADIUS(1)
    ) filter_i (
        .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
        .cmd_valid(state == ST_COMMAND), .cmd_ready(cmd_ready),
        .cmd_tag(8'h5a), .cfg_width(16'd4), .cfg_height(16'd4),
        .cfg_structuring_element(9'b111111111),
        .cfg_patch_radius(8'd1), .cfg_search_radius(8'd1), .cfg_h_q8(16'd256),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_tag(rsp_tag),
        .rsp_error(rsp_error), .s_data(s_data), .s_valid(s_valid),
        .s_sof(s_sof), .s_eol(s_eol), .s_ready(s_ready),
        .m_data(m_data), .m_valid(m_valid), .m_sof(m_sof), .m_eol(m_eol),
        .m_ready(m_ready)
    );

    function [7:0] hex_ascii;
        input [3:0] value;
        begin
            if (value < 10) hex_ascii = 8'h30 + value;
            else hex_ascii = 8'h41 + value - 10;
        end
    endfunction

    function [7:0] report_byte;
        input [4:0] index;
        input is_fail;
        input [31:0] digest;
        begin
            case (index)
                0: report_byte = "F";
                1: report_byte = "I";
                2: report_byte = "L";
                3: report_byte = "T";
                4: report_byte = "E";
                5: report_byte = "R";
                6: report_byte = " ";
                7: report_byte = is_fail ? "F" : "P";
                8: report_byte = is_fail ? "A" : "A";
                9: report_byte = is_fail ? "I" : "S";
                10: report_byte = is_fail ? "L" : "S";
                11: report_byte = " ";
                12: report_byte = "D";
                13: report_byte = "=";
                14: report_byte = hex_ascii(digest[31:28]);
                15: report_byte = hex_ascii(digest[27:24]);
                16: report_byte = hex_ascii(digest[23:20]);
                17: report_byte = hex_ascii(digest[19:16]);
                18: report_byte = hex_ascii(digest[15:12]);
                19: report_byte = hex_ascii(digest[11:8]);
                20: report_byte = hex_ascii(digest[7:4]);
                21: report_byte = hex_ascii(digest[3:0]);
                22: report_byte = 8'h0d;
                default: report_byte = 8'h0a;
            endcase
        end
    endfunction

    reg tx_busy;
    reg [9:0] tx_shift;
    reg [3:0] tx_bit;
    reg [15:0] tx_timer;
    reg [4:0] report_index;
    reg [31:0] watchdog;
    assign dbg_uart = passed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_COMMAND;
            input_index <= 0;
            output_index <= 0;
            output_digest <= 0;
            failed <= 0;
            passed <= 0;
            error_code <= 0;
            tx_busy <= 0;
            tx_shift <= 10'h3ff;
            tx_bit <= 0;
            tx_timer <= 0;
            report_index <= 0;
            watchdog <= 0;
            uart_tx <= 1'b1;
        end else begin
            if (state != ST_DONE && state != ST_REPORT) begin
                watchdog <= watchdog + 1'b1;
                if (&watchdog) begin
                    failed <= 1'b1;
                    error_code <= 8'hff;
                    state <= ST_REPORT;
                end
            end
            case (state)
                ST_COMMAND: if (cmd_ready) begin
                    input_index <= 0;
                    state <= ST_INPUT;
                end
                ST_INPUT: if (s_valid && s_ready) begin
                    if (input_index == 15) begin
                        output_index <= 0;
                        state <= ST_OUTPUT;
                    end else input_index <= input_index + 1'b1;
                end
                ST_OUTPUT: if (m_valid && m_ready) begin
                    if (m_data != expected_pixel(output_index) ||
                        m_sof != (output_index == 0) ||
                        m_eol != (output_index[1:0] == 2'b11)) begin
                        failed <= 1'b1;
                        error_code <= 8'h01;
                    end
                    output_digest <= {output_digest[26:0], output_digest[31:27]} ^ {24'd0,m_data};
                    if (output_index == 15) state <= ST_RESPONSE;
                    else output_index <= output_index + 1'b1;
                end
                ST_RESPONSE: if (rsp_valid) begin
                    if (rsp_error != 0 || rsp_tag != 8'h5a || failed) begin
                        failed <= 1'b1;
                        if (rsp_error != 0) error_code <= rsp_error;
                    end else passed <= 1'b1;
                    state <= ST_REPORT;
                    report_index <= 0;
                end
                ST_REPORT: begin
                    if (!tx_busy) begin
                        if (report_index == REPORT_LENGTH) state <= ST_DONE;
                        else begin
                            tx_shift <= {1'b1,report_byte(report_index,failed,output_digest),1'b0};
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
                        tx_shift <= {1'b1,tx_shift[9:1]};
                        uart_tx <= tx_shift[1];
                        tx_bit <= tx_bit + 1'b1;
                        tx_timer <= BAUD_DIV - 1;
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule

`default_nettype wire
