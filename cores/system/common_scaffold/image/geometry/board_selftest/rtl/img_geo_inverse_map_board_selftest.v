// Tang Primer 25K board-visible self-test for img_geo_inverse_map.
// Runs a fixed 4x4 perspective map and compares every Q16.8 coordinate and
// marker against a compile-time golden table. UART sends only GEOMAP PASS or
// GEOMAP FAIL (CR/LF terminated), repeating once per second for easy capture.
module img_geo_inverse_map_board_selftest #(
    parameter integer CLK_HZ = 50000000,
    parameter integer UART_BAUD = 115200,
    parameter integer POR_CYCLES = 1000000,
    parameter integer REPORT_REPEAT_CYCLES = 50000000
) (
    input wire clk,       // Tang Primer 25K Dock E2, 50 MHz
    input wire rst,       // Tang Primer 25K Dock H11, active high key
    output wire uart_tx   // Tang Primer 25K Dock C3, debugger UART channel B
);
localparam integer UART_CLKS_PER_BIT = (CLK_HZ + UART_BAUD/2) / UART_BAUD;
localparam [2:0] ST_ISSUE=3'd0, ST_WAIT_RESULT=3'd1,
                 ST_REPORT=3'd2, ST_REPORT_GAP=3'd3;
localparam [3:0] LAST_PIXEL=4'd15;
localparam [3:0] LAST_REPORT_CHAR=4'd12;

reg [31:0] por_count=0;
reg por_done=0;
wire rst_n = !rst && por_done;
always @(posedge clk) begin
    if (rst) begin
        por_count<=0;
        por_done<=0;
    end else if (!por_done) begin
        if (POR_CYCLES<=1 || por_count>=POR_CYCLES-1) begin
            por_done<=1;
        end else begin
            por_count<=por_count+1'b1;
        end
    end
end

reg [2:0] state;
reg [3:0] pixel_index;
reg failed;
wire inverse_s_ready, inverse_m_valid;
wire [23:0] inverse_m_x_q8, inverse_m_y_q8;
wire inverse_m_border;
wire [3:0] inverse_m_error;
wire inverse_m_sof, inverse_m_eol, inverse_m_eof;

wire [15:0] pixel_x={14'd0,pixel_index[1:0]};
wire [15:0] pixel_y={14'd0,pixel_index[3:2]};
wire pixel_sof=(pixel_index==4'd0);
wire pixel_eol=(pixel_index[1:0]==2'd3);
wire pixel_eof=(pixel_index==LAST_PIXEL);

img_geo_inverse_map inverse_map (
    .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
    .s_valid(state==ST_ISSUE),.s_ready(inverse_s_ready),
    .s_x(pixel_x),.s_y(pixel_y),
    .s_sof(pixel_sof),.s_eol(pixel_eol),.s_eof(pixel_eof),
    .s_mode(4'd8),
    .s_src_width(16'd4),.s_src_height(16'd4),
    .s_dst_width(16'd4),.s_dst_height(16'd4),
    // x' = x / (1 + x/8), y' = y / (1 + x/8), Q16.16 matrix.
    .s_h00(32'sd65536),.s_h01(32'sd0),.s_h02(32'sd0),
    .s_h10(32'sd0),.s_h11(32'sd65536),.s_h12(32'sd0),
    .s_h20(32'sd8192),.s_h21(32'sd0),.s_h22(32'sd65536),
    .m_valid(inverse_m_valid),.m_ready(1'b1),
    .m_x_q8(inverse_m_x_q8),.m_y_q8(inverse_m_y_q8),
    .m_border(inverse_m_border),.m_error(inverse_m_error),
    .m_sof(inverse_m_sof),.m_eol(inverse_m_eol),.m_eof(inverse_m_eof)
);

function [23:0] golden_x;
    input [3:0] index;
    begin
        case (index)
            4'd0,4'd4,4'd8,4'd12: golden_x=24'd0;
            4'd1,4'd5,4'd9,4'd13: golden_x=24'd227;
            4'd2,4'd6,4'd10,4'd14: golden_x=24'd409;
            4'd3,4'd7,4'd11,4'd15: golden_x=24'd558;
            default: golden_x=24'd0;
        endcase
    end
endfunction

function [23:0] golden_y;
    input [3:0] index;
    begin
        case (index)
            4'd0: golden_y=24'd0;
            4'd1: golden_y=24'd0;
            4'd2: golden_y=24'd0;
            4'd3: golden_y=24'd0;
            4'd4: golden_y=24'd256;
            4'd5: golden_y=24'd227;
            4'd6: golden_y=24'd204;
            4'd7: golden_y=24'd186;
            4'd8: golden_y=24'd512;
            4'd9: golden_y=24'd455;
            4'd10: golden_y=24'd409;
            4'd11: golden_y=24'd372;
            4'd12: golden_y=24'd768;
            4'd13: golden_y=24'd682;
            4'd14: golden_y=24'd614;
            4'd15: golden_y=24'd558;
            default: golden_y=24'd0;
        endcase
    end
endfunction

reg [3:0] report_index;
reg [31:0] report_pause;
reg uart_valid;
reg [7:0] uart_data;
wire uart_ready;

function [7:0] report_char;
    input [3:0] index;
    input pass;
    begin
        case (index)
            4'd0: report_char="G";
            4'd1: report_char="E";
            4'd2: report_char="O";
            4'd3: report_char="M";
            4'd4: report_char="A";
            4'd5: report_char="P";
            4'd6: report_char=" ";
            4'd7: report_char=pass ? "P" : "F";
            4'd8: report_char="A";
            4'd9: report_char=pass ? "S" : "I";
            4'd10: report_char=pass ? "S" : "L";
            4'd11: report_char=8'd13;
            4'd12: report_char=8'd10;
            default: report_char=8'd32;
        endcase
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state<=ST_ISSUE;
        pixel_index<=0;
        failed<=0;
        report_index<=0;
        report_pause<=0;
        uart_valid<=0;
        uart_data<=8'd0;
    end else begin
        case (state)
            ST_ISSUE: begin
                if (inverse_s_ready)
                    state<=ST_WAIT_RESULT;
            end
            ST_WAIT_RESULT: begin
                if (inverse_m_valid) begin
                    if (inverse_m_x_q8!==golden_x(pixel_index) ||
                        inverse_m_y_q8!==golden_y(pixel_index) ||
                        inverse_m_border!==1'b0 || inverse_m_error!==4'd0 ||
                        inverse_m_sof!==pixel_sof ||
                        inverse_m_eol!==pixel_eol || inverse_m_eof!==pixel_eof)
                        failed<=1;
                    if (pixel_index==LAST_PIXEL) begin
                        state<=ST_REPORT;
                        report_index<=0;
                    end else begin
                        pixel_index<=pixel_index+1'b1;
                        state<=ST_ISSUE;
                    end
                end
            end
            ST_REPORT: begin
                if (!uart_valid && uart_ready) begin
                    uart_data<=report_char(report_index,!failed);
                    uart_valid<=1;
                end else if (uart_valid && uart_ready) begin
                    uart_valid<=0;
                    if (report_index==LAST_REPORT_CHAR) begin
                        report_index<=0;
                        report_pause<=0;
                        state<=ST_REPORT_GAP;
                    end else begin
                        report_index<=report_index+1'b1;
                    end
                end
            end
            ST_REPORT_GAP: begin
                if (REPORT_REPEAT_CYCLES<=1 || report_pause>=REPORT_REPEAT_CYCLES-1) begin
                    report_pause<=0;
                    state<=ST_REPORT;
                end else begin
                    report_pause<=report_pause+1'b1;
                end
            end
            default: begin
                state<=ST_ISSUE;
                uart_valid<=0;
            end
        endcase
    end
end

geo_uart_tx_byte #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) uart_tx_driver (
    .clk(clk),.rst_n(rst_n),.valid(uart_valid),.data(uart_data),
    .ready(uart_ready),.tx(uart_tx)
);
endmodule

module geo_uart_tx_byte #(
    parameter integer CLKS_PER_BIT=434
) (
    input wire clk,
    input wire rst_n,
    input wire valid,
    input wire [7:0] data,
    output wire ready,
    output reg tx
);
reg busy;
reg [15:0] bit_count;
reg [3:0] bit_index;
reg [9:0] shift;
assign ready=!busy;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy<=0; bit_count<=0; bit_index<=0; shift<=10'h3ff; tx<=1;
    end else if (!busy) begin
        tx<=1;
        if (valid) begin
            busy<=1; bit_count<=0; bit_index<=0;
            shift<={1'b1,data,1'b0}; tx<=1'b0;
        end
    end else if (bit_count==CLKS_PER_BIT-1) begin
        bit_count<=0;
        if (bit_index==4'd9) begin
            busy<=0; tx<=1;
        end else begin
            shift<={1'b1,shift[9:1]};
            bit_index<=bit_index+1'b1;
            tx<=shift[1];
        end
    end else begin
        bit_count<=bit_count+1'b1;
    end
end
endmodule
