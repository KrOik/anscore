`timescale 1ns/1ps
module tb_img_geo_inverse_map_board_selftest;
    localparam integer CLK_HZ=50000000;
    localparam integer UART_BAUD=115200;
    localparam integer CLKS_PER_BIT=(CLK_HZ+UART_BAUD/2)/UART_BAUD;
    reg clk=0;
    always #10 clk=~clk;
    reg rst=1;
    wire uart_tx;
    reg [7:0] received;
    integer i;

    img_geo_inverse_map_board_selftest #(
        .CLK_HZ(CLK_HZ),.UART_BAUD(UART_BAUD),
        .POR_CYCLES(4),.REPORT_REPEAT_CYCLES(1000000)
    ) dut (.clk(clk),.rst(rst),.uart_tx(uart_tx));

    function [7:0] expected_char;
        input integer index;
        begin
            case (index)
                0: expected_char="G";
                1: expected_char="E";
                2: expected_char="O";
                3: expected_char="M";
                4: expected_char="A";
                5: expected_char="P";
                6: expected_char=" ";
                7: expected_char="P";
                8: expected_char="A";
                9: expected_char="S";
                10: expected_char="S";
                11: expected_char=8'd13;
                12: expected_char=8'd10;
                default: expected_char=8'd0;
            endcase
        end
    endfunction

    task automatic receive_uart_byte(output reg [7:0] data);
        integer bit_index;
        begin
            wait (uart_tx===1'b0);
            // First data bit center: 1.5 bit periods after the start edge.
            repeat (CLKS_PER_BIT + CLKS_PER_BIT/2) @(posedge clk);
            data[0]=uart_tx;
            for (bit_index=1;bit_index<8;bit_index=bit_index+1) begin
                repeat (CLKS_PER_BIT) @(posedge clk);
                data[bit_index]=uart_tx;
            end
            repeat (CLKS_PER_BIT) @(posedge clk);
            if (uart_tx!==1'b1) $fatal(1,"UART stop bit was not high");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst=0;
        for (i=0;i<13;i=i+1) begin
            receive_uart_byte(received);
            if (received!==expected_char(i))
                $fatal(1,"UART byte %0d got 0x%02x expected 0x%02x",
                    i,received,expected_char(i));
        end
        $display("PASS tb_img_geo_inverse_map_board_selftest GEOMAP PASS");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1,"self-test UART timeout");
    end
endmodule
