`timescale 1ns/1ps

module tb_image_bilateral_selftest_25k #(parameter integer TEST_MODE=0);
    localparam integer BIT_NS=8680;
    reg clk=0;
    reg uart_rx_pin=1;
    wire uart_tx,dbg_uart;
    integer bit_index,byte_count;
    reg [7:0] received_byte;
    string message;
    always #10 clk=~clk;

    image_bilateral_selftest_25k #(.TEST_MODE(TEST_MODE)) dut(
        .clk(clk),.uart_rx_pin(uart_rx_pin),.uart_tx(uart_tx),.dbg_uart(dbg_uart)
    );

    function [7:0] expected_uart_byte;
        input integer index;
        begin
            case(index)
                0:expected_uart_byte="B"; 1:expected_uart_byte="I";
                2:expected_uart_byte="L"; 3:expected_uart_byte="A";
                4:expected_uart_byte="T"; 5:expected_uart_byte=" ";
                6:expected_uart_byte="P"; 7:expected_uart_byte="A";
                8:expected_uart_byte="S"; 9:expected_uart_byte="S";
                10:expected_uart_byte=" "; 11:expected_uart_byte="M";
                12:expected_uart_byte="="; 13:expected_uart_byte="6";
                14:expected_uart_byte="4"; 15:expected_uart_byte=" ";
                16:expected_uart_byte="D"; 17:expected_uart_byte="=";
                18:expected_uart_byte="0"; 19:expected_uart_byte="0";
                20:expected_uart_byte="0"; 21:expected_uart_byte="0";
                22:expected_uart_byte="0"; 23:expected_uart_byte="0";
                24:expected_uart_byte="6"; 25:expected_uart_byte="4";
                26:expected_uart_byte=8'h0d;
                default:expected_uart_byte=8'h0a;
            endcase
        end
    endfunction

    initial begin
        byte_count=0; message="";
        @(negedge uart_tx);
        forever begin
            #(BIT_NS*1.5);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                received_byte[bit_index]=uart_tx;
                #BIT_NS;
            end
            if(uart_tx!==1'b1) $fatal(1,"UART stop bit low");
            message={message,received_byte};
            if(received_byte!==expected_uart_byte(byte_count))
                $fatal(1,"UART byte %0d expected %02x got %02x",byte_count,
                       expected_uart_byte(byte_count),received_byte);
            byte_count=byte_count+1;
            if(received_byte==8'h0a) begin
                if(byte_count!=28) $fatal(1,"UART message length %0d",byte_count);
                if(dut.failed || !dut.passed || dut.output_digest!=32'h00000064)
                    $fatal(1,"state/digest mismatch failed=%0d passed=%0d digest=%08x",
                           dut.failed,dut.passed,dut.output_digest);
                if(dbg_uart!==1'b1) $fatal(1,"PASS debug pin not asserted");
                $display("PASS image_bilateral_selftest_25k: %s",message);
                $finish;
            end
            @(negedge uart_tx);
        end
    end

    initial begin
        #20_000_000;
        $fatal(1,"board self-test timed out");
    end
endmodule
