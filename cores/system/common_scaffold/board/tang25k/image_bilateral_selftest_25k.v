`default_nettype none

// Board-visible consistency test for the bilateral 3x3 denoiser.
// A dark outlier in a bright neighborhood must be rejected by the range
// weight, leaving the center value unchanged.
module image_bilateral_selftest_25k #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer TEST_MODE = 0
) (
    input wire clk,
    input wire uart_rx_pin,
    output reg uart_tx,
    output wire dbg_uart
);
    localparam integer BAUD_DIV = CLK_HZ / BAUD;
    localparam [2:0] ST_COMMAND=0, ST_RESPONSE=1, ST_INPUT=2,
                     ST_OUTPUT=3, ST_REPORT=4, ST_DONE=5;
    localparam integer REPORT_LENGTH=28;

    reg [15:0] por_count=0;
    always @(posedge clk) if (!por_count[15]) por_count<=por_count+1'b1;
    wire rst_n=por_count[15];

    reg [2:0] state;
    reg [23:0] watchdog;
    reg [31:0] output_digest;
    reg [7:0] last_result;
    reg failed,passed;
    reg [4:0] report_index;
    reg tx_busy;
    reg [9:0] tx_shift;
    reg [3:0] tx_bit;
    reg [15:0] tx_timer;

    wire cmd_ready,rsp_valid,s_ready,m_valid,m_sof,m_eol;
    wire [7:0] rsp_tag,rsp_error;
    wire [7:0] m_data;
    wire [71:0] taps;
    wire cmd_valid=(state==ST_COMMAND);
    wire rsp_ready=1'b1;
    wire s_valid=(state==ST_INPUT);
    wire s_sof=1'b1, s_eol=1'b1;
    wire m_ready=1'b1;

    // Tap zero is the outlier. The center and all other taps are 100.
    // sigma_range=16/256 makes the 100-level outlier's table weight zero.
    assign taps=TEST_MODE ? {9{8'd100}} :
                {8'd100,8'd100,8'd100,8'd100,8'd100,
                 8'd100,8'd100,8'd100,8'd0};

    img_filter_bilateral3x3 #(.PIXEL_W(8)) dut (
        .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_tag(8'h5a),
        .cfg_sigma_spatial_q8(16'd256),.cfg_sigma_range_q8(16'd16),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_tag(rsp_tag),
        .rsp_error(rsp_error),.s_taps(taps),.s_valid(s_valid),
        .s_sof(s_sof),.s_eol(s_eol),.s_ready(s_ready),
        .m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),
        .m_ready(m_ready)
    );

    function [7:0] hex_ascii;
        input [3:0] value;
        begin
            if(value<10) hex_ascii=8'h30+value;
            else hex_ascii=8'h41+value-10;
        end
    endfunction

    function [7:0] report_byte;
        input [4:0] index;
        input is_fail;
        input [31:0] digest;
        input [7:0] pixel;
        begin
            case(index)
                0:report_byte="B"; 1:report_byte="I"; 2:report_byte="L";
                3:report_byte="A"; 4:report_byte="T"; 5:report_byte=" ";
                6:report_byte=is_fail?"F":"P";
                7:report_byte="A";
                8:report_byte=is_fail?"I":"S";
                9:report_byte=is_fail?"L":"S";
                10:report_byte=" "; 11:report_byte="M"; 12:report_byte="=";
                13:report_byte=hex_ascii(pixel[7:4]);
                14:report_byte=hex_ascii(pixel[3:0]);
                15:report_byte=" "; 16:report_byte="D"; 17:report_byte="=";
                18:report_byte=hex_ascii(digest[31:28]);
                19:report_byte=hex_ascii(digest[27:24]);
                20:report_byte=hex_ascii(digest[23:20]);
                21:report_byte=hex_ascii(digest[19:16]);
                22:report_byte=hex_ascii(digest[15:12]);
                23:report_byte=hex_ascii(digest[11:8]);
                24:report_byte=hex_ascii(digest[7:4]);
                25:report_byte=hex_ascii(digest[3:0]);
                26:report_byte=8'h0d;
                default:report_byte=8'h0a;
            endcase
        end
    endfunction

    assign dbg_uart=passed;
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=ST_COMMAND; watchdog<=0; output_digest<=0;
            failed<=0; passed<=0; last_result<=0; report_index<=0;
            tx_busy<=0; tx_shift<=10'h3ff; tx_bit<=0; tx_timer<=0;
            uart_tx<=1'b1;
        end else if(state!=ST_REPORT && state!=ST_DONE && (&watchdog)) begin
            failed<=1'b1; state<=ST_REPORT; report_index<=0;
        end else begin
            if(state!=ST_REPORT && state!=ST_DONE) watchdog<=watchdog+1'b1;
            case(state)
                ST_COMMAND: if(cmd_ready) state<=ST_RESPONSE;
                ST_RESPONSE: if(rsp_valid) begin
                    if(rsp_error!=0 || rsp_tag!=8'h5a) begin
                        failed<=1'b1; state<=ST_REPORT; report_index<=0;
                    end else state<=ST_INPUT;
                end
                ST_INPUT: if(s_valid && s_ready) state<=ST_OUTPUT;
                ST_OUTPUT: if(m_valid && m_ready) begin
                    last_result<=m_data;
                    output_digest<={output_digest[26:0],output_digest[31:27]}
                                   ^ {24'd0,m_data};
                    if(m_data!=8'd100 || !m_sof || !m_eol) failed<=1'b1;
                    else passed<=1'b1;
                    state<=ST_REPORT; report_index<=0;
                end
                ST_REPORT: begin
                    if(!tx_busy) begin
                        if(report_index==REPORT_LENGTH) state<=ST_DONE;
                        else begin
                            tx_shift<={1'b1,report_byte(report_index,failed,output_digest,last_result),1'b0};
                            tx_bit<=0; tx_timer<=BAUD_DIV-1; tx_busy<=1'b1;
                            uart_tx<=1'b0;
                        end
                    end else if(tx_timer!=0) tx_timer<=tx_timer-1'b1;
                    else if(tx_bit==9) begin
                        tx_busy<=0; uart_tx<=1'b1; report_index<=report_index+1'b1;
                    end else begin
                        tx_shift<={1'b1,tx_shift[9:1]}; uart_tx<=tx_shift[1];
                        tx_bit<=tx_bit+1'b1; tx_timer<=BAUD_DIV-1;
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule

`default_nettype wire
