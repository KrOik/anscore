`timescale 1ns / 1ps

module tb_top_uart_report;

localparam integer UART_CYCLE = 234;
localparam integer MSG_LEN = 194;

reg clk = 1'b0;
wire uart_tx_pin;
wire status_pass;
wire status_fail;

integer failures = 0;
integer index;
reg [7:0] rx_byte;

always #5 clk = ~clk;

top dut (
    .clk(clk),
    .uart_tx_pin(uart_tx_pin),
    .status_pass(status_pass),
    .status_fail(status_fail)
);

function [7:0] expected_char;
    input integer char_index;
    begin
        case (char_index)
            0: expected_char = "N";
            1: expected_char = "2";
            2: expected_char = "5";
            3: expected_char = "6";
            4: expected_char = " ";
            5: expected_char = "P";
            6: expected_char = "A";
            7: expected_char = "S";
            8: expected_char = "S";
            9: expected_char = " ";
            10: expected_char = "D";
            11: expected_char = "=";
            12: expected_char = "2";
            13: expected_char = "F";
            14: expected_char = "9";
            15: expected_char = "C";
            16: expected_char = "9";
            17: expected_char = "4";
            18: expected_char = "A";
            19: expected_char = "D";
            20: expected_char = " ";
            21: expected_char = "C";
            22: expected_char = "=";
            23: expected_char = "0";
            24: expected_char = "0";
            25: expected_char = "0";
            26: expected_char = "0";
            27: expected_char = "9";
            28: expected_char = "7";
            29: expected_char = "9";
            30: expected_char = "A";
            31: expected_char = 8'h0d;
            32: expected_char = 8'h0a;
            33: expected_char = "O";
            34: expected_char = "P";
            35: expected_char = "S";
            36: expected_char = "4";
            37: expected_char = " ";
            38: expected_char = "P";
            39: expected_char = "A";
            40: expected_char = "S";
            41: expected_char = "S";
            42: expected_char = " ";
            43: expected_char = "D";
            44: expected_char = "=";
            45: expected_char = "4";
            46: expected_char = "4";
            47: expected_char = "4";
            48: expected_char = "A";
            49: expected_char = "5";
            50: expected_char = "0";
            51: expected_char = "3";
            52: expected_char = "2";
            53: expected_char = 8'h0d;
            54: expected_char = 8'h0a;
            55: expected_char = "F";
            56: expected_char = "L";
            57: expected_char = "O";
            58: expected_char = "W";
            59: expected_char = " ";
            60: expected_char = "P";
            61: expected_char = "A";
            62: expected_char = "S";
            63: expected_char = "S";
            64: expected_char = " ";
            65: expected_char = "K";
            66: expected_char = "=";
            67: expected_char = "E";
            68: expected_char = "D";
            69: expected_char = "A";
            70: expected_char = "A";
            71: expected_char = "6";
            72: expected_char = "3";
            73: expected_char = "5";
            74: expected_char = "4";
            75: expected_char = " ";
            76: expected_char = "D";
            77: expected_char = "=";
            78: expected_char = "E";
            79: expected_char = "9";
            80: expected_char = "B";
            81: expected_char = "0";
            82: expected_char = "6";
            83: expected_char = "0";
            84: expected_char = "5";
            85: expected_char = "2";
            86: expected_char = 8'h0d;
            87: expected_char = 8'h0a;
            88: expected_char = "P";
            89: expected_char = "I";
            90: expected_char = "P";
            91: expected_char = "E";
            92: expected_char = " ";
            93: expected_char = "P";
            94: expected_char = "A";
            95: expected_char = "S";
            96: expected_char = "S";
            97: expected_char = " ";
            98: expected_char = "B";
            99: expected_char = "=";
            100: expected_char = "0";
            101: expected_char = "0";
            102: expected_char = "0";
            103: expected_char = "0";
            104: expected_char = " ";
            105: expected_char = "P";
            106: expected_char = "=";
            107: expected_char = "F";
            108: expected_char = "F";
            109: expected_char = "F";
            110: expected_char = "F";
            111: expected_char = 8'h0d;
            112: expected_char = 8'h0a;
            113: expected_char = "S";
            114: expected_char = "Y";
            115: expected_char = "S";
            116: expected_char = "T";
            117: expected_char = " ";
            118: expected_char = "P";
            119: expected_char = "A";
            120: expected_char = "S";
            121: expected_char = "S";
            122: expected_char = " ";
            123: expected_char = "D";
            124: expected_char = "=";
            125: expected_char = "0";
            126: expected_char = "B";
            127: expected_char = "1";
            128: expected_char = "A";
            129: expected_char = "0";
            130: expected_char = "3";
            131: expected_char = "0";
            132: expected_char = "6";
            133: expected_char = " ";
            134: expected_char = "B";
            135: expected_char = "=";
            136: expected_char = "0";
            137: expected_char = "0";
            138: expected_char = "0";
            139: expected_char = "0";
            140: expected_char = " ";
            141: expected_char = "I";
            142: expected_char = "=";
            143: expected_char = "1";
            144: expected_char = "2";
            145: expected_char = "0";
            146: expected_char = "0";
            147: expected_char = 8'h0d;
            148: expected_char = 8'h0a;
            149: expected_char = "F";
            150: expected_char = "U";
            151: expected_char = "L";
            152: expected_char = "L";
            153: expected_char = " ";
            154: expected_char = "P";
            155: expected_char = "A";
            156: expected_char = "S";
            157: expected_char = "S";
            158: expected_char = " ";
            159: expected_char = "D";
            160: expected_char = "=";
            161: expected_char = "C";
            162: expected_char = "4";
            163: expected_char = "0";
            164: expected_char = "9";
            165: expected_char = "0";
            166: expected_char = "C";
            167: expected_char = "1";
            168: expected_char = "7";
            169: expected_char = " ";
            170: expected_char = "B";
            171: expected_char = "=";
            172: expected_char = "0";
            173: expected_char = "0";
            174: expected_char = "0";
            175: expected_char = "0";
            176: expected_char = " ";
            177: expected_char = "O";
            178: expected_char = "=";
            179: expected_char = "0";
            180: expected_char = "C";
            181: expected_char = "0";
            182: expected_char = "0";
            183: expected_char = " ";
            184: expected_char = "L";
            185: expected_char = "=";
            186: expected_char = "0";
            187: expected_char = "0";
            188: expected_char = "1";
            189: expected_char = "7";
            190: expected_char = 8'h0d;
            191: expected_char = 8'h0a;
            192: expected_char = 8'h0d;
            193: expected_char = 8'h0a;
            default: expected_char = 8'h00;
        endcase
    end
endfunction

task automatic read_uart_byte;
    output [7:0] value;
    integer bit_index;
    begin
        @(negedge uart_tx_pin);
        repeat (UART_CYCLE + (UART_CYCLE / 2)) @(posedge clk);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            value[bit_index] = uart_tx_pin;
            repeat (UART_CYCLE) @(posedge clk);
        end
        if (uart_tx_pin !== 1'b1) begin
            $display("FAIL UART stop bit low");
            failures = failures + 1;
        end
        repeat (UART_CYCLE / 2) @(posedge clk);
    end
endtask

initial begin
    wait (status_pass || status_fail);
    if (!status_pass || status_fail) begin
        $display("FAIL self-test status pass=%0d fail=%0d", status_pass, status_fail);
        $fatal(1);
    end

    for (index = 0; index < MSG_LEN; index = index + 1) begin
        read_uart_byte(rx_byte);
        if (rx_byte !== expected_char(index)) begin
            $display("FAIL char[%0d]=0x%02x expected=0x%02x", index, rx_byte, expected_char(index));
            failures = failures + 1;
        end
    end

    if (failures == 0) begin
        $display("tb_top_uart_report PASS");
        $finish;
    end else begin
        $display("tb_top_uart_report FAIL failures=%0d", failures);
        $fatal(1);
    end
end

initial begin
    repeat (900000) @(posedge clk);
    $display("tb_top_uart_report FAIL timeout");
    $fatal(1);
end

endmodule
