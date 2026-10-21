`timescale 1ns/1ps

module tb_dehaze_guided_refine_selftest_25k;
    localparam integer BIT_NS = 8680; // 50 MHz / 115200, rounded to 434 clocks
    reg clk = 1'b0;
    reg uart_rx_pin = 1'b1;
    wire uart_tx;
    wire dbg_uart;
    integer bit_index;
    integer byte_count;
    reg [7:0] received_byte;
    reg signed [63:0] sim_first_sum_a, sim_first_sum_b;
    reg sim_first_sum_seen;
    reg signed [47:0] sim_first_a_value, sim_first_b_value;
    reg sim_first_coeff_seen;

    always #10 clk = ~clk;

    always @(posedge clk) begin
        if (dut.guided_refine_i.state == dut.guided_refine_i.A_STORE &&
            dut.guided_refine_i.index == 0 && !sim_first_coeff_seen) begin
            sim_first_a_value <= dut.guided_refine_i.a_value;
            sim_first_b_value <= dut.guided_refine_i.b_value;
            sim_first_coeff_seen <= 1'b1;
        end
        if (dut.m_valid && dut.output_index == 0 && !sim_first_sum_seen) begin
            sim_first_sum_a <= dut.guided_refine_i.sum_a;
            sim_first_sum_b <= dut.guided_refine_i.sum_b;
            sim_first_sum_seen <= 1'b1;
        end
    end

    dehaze_guided_refine_selftest_25k dut (
        .clk(clk), .uart_rx_pin(uart_rx_pin), .uart_tx(uart_tx),
        .dbg_uart(dbg_uart)
    );

    function [7:0] expected_uart_byte;
        input integer index;
        begin
            case (index)
                0: expected_uart_byte = "D";
                1: expected_uart_byte = "H";
                2: expected_uart_byte = "R";
                3: expected_uart_byte = "F";
                4: expected_uart_byte = " ";
                5: expected_uart_byte = "P";
                6: expected_uart_byte = "A";
                7: expected_uart_byte = "S";
                8: expected_uart_byte = "S";
                9: expected_uart_byte = " ";
                10: expected_uart_byte = "D";
                11: expected_uart_byte = "=";
                12: expected_uart_byte = "6";
                13: expected_uart_byte = "9";
                14: expected_uart_byte = "B";
                15: expected_uart_byte = "9";
                16: expected_uart_byte = "F";
                17: expected_uart_byte = "7";
                18: expected_uart_byte = "5";
                19: expected_uart_byte = "9";
                20: expected_uart_byte = " ";
                21: expected_uart_byte = "E";
                22: expected_uart_byte = "=";
                23: expected_uart_byte = "0";
                24: expected_uart_byte = "0";
                25: expected_uart_byte = " ";
                26: expected_uart_byte = "I";
                27: expected_uart_byte = "=";
                28: expected_uart_byte = "0";
                29: expected_uart_byte = " ";
                30: expected_uart_byte = "M";
                31: expected_uart_byte = "=";
                32: expected_uart_byte = "0";
                33: expected_uart_byte = "0";
                34: expected_uart_byte = "0";
                35: expected_uart_byte = "0";
                36: expected_uart_byte = " ";
                37: expected_uart_byte = "A";
                38: expected_uart_byte = "=";
                39: expected_uart_byte = "0";
                40: expected_uart_byte = "0";
                41: expected_uart_byte = "0";
                42: expected_uart_byte = "0";
                43: expected_uart_byte = "0";
                44: expected_uart_byte = "0";
                45: expected_uart_byte = "0";
                46: expected_uart_byte = "0";
                47: expected_uart_byte = "0";
                48: expected_uart_byte = "0";
                49: expected_uart_byte = "0";
                50: expected_uart_byte = "0";
                51: expected_uart_byte = " ";
                52: expected_uart_byte = "B";
                53: expected_uart_byte = "=";
                66: expected_uart_byte = " ";
                67: expected_uart_byte = "S";
                68: expected_uart_byte = "I";
                69: expected_uart_byte = "=";
                78: expected_uart_byte = " ";
                79: expected_uart_byte = "S";
                80: expected_uart_byte = "P";
                81: expected_uart_byte = "=";
                90: expected_uart_byte = " ";
                91: expected_uart_byte = "S";
                92: expected_uart_byte = "I";
                93: expected_uart_byte = "I";
                94: expected_uart_byte = "=";
                103: expected_uart_byte = " ";
                104: expected_uart_byte = "S";
                105: expected_uart_byte = "I";
                106: expected_uart_byte = "P";
                107: expected_uart_byte = "=";
                116: expected_uart_byte = " ";
                117: expected_uart_byte = "F";
                118: expected_uart_byte = "=";
                120: expected_uart_byte = " ";
                121: expected_uart_byte = "A";
                122: expected_uart_byte = "N";
                123: expected_uart_byte = "=";
                140: expected_uart_byte = " ";
                141: expected_uart_byte = "A";
                142: expected_uart_byte = "D";
                143: expected_uart_byte = "=";
                160: expected_uart_byte = " ";
                161: expected_uart_byte = "B";
                162: expected_uart_byte = "N";
                163: expected_uart_byte = "=";
                180: expected_uart_byte = " ";
                181: expected_uart_byte = "B";
                182: expected_uart_byte = "D";
                183: expected_uart_byte = "=";
                200: expected_uart_byte = " ";
                201: expected_uart_byte = "Q";
                202: expected_uart_byte = "M";
                203: expected_uart_byte = "=";
                220: expected_uart_byte = " ";
                221: expected_uart_byte = "R";
                222: expected_uart_byte = "M";
                223: expected_uart_byte = "=";
                240: expected_uart_byte = " ";
                241: expected_uart_byte = "B";
                242: expected_uart_byte = "Q";
                243: expected_uart_byte = "=";
                260: expected_uart_byte = " ";
                261: expected_uart_byte = "S";
                262: expected_uart_byte = "A";
                263: expected_uart_byte = "=";
                280: expected_uart_byte = " ";
                281: expected_uart_byte = "S";
                282: expected_uart_byte = "B";
                283: expected_uart_byte = "=";
                300: expected_uart_byte = " ";
                301: expected_uart_byte = "Q";
                302: expected_uart_byte = "N";
                303: expected_uart_byte = "=";
                320: expected_uart_byte = " ";
                321: expected_uart_byte = "Q";
                322: expected_uart_byte = "D";
                323: expected_uart_byte = "=";
                340: expected_uart_byte = " ";
                341: expected_uart_byte = "Q";
                342: expected_uart_byte = "Q";
                343: expected_uart_byte = "=";
                360: expected_uart_byte = " ";
                361: expected_uart_byte = "A";
                362: expected_uart_byte = "1";
                363: expected_uart_byte = "=";
                376: expected_uart_byte = " ";
                377: expected_uart_byte = "A";
                378: expected_uart_byte = "3";
                379: expected_uart_byte = "=";
                392: expected_uart_byte = " ";
                393: expected_uart_byte = "A";
                394: expected_uart_byte = "4";
                395: expected_uart_byte = "=";
                408: expected_uart_byte = " ";
                409: expected_uart_byte = "B";
                410: expected_uart_byte = "1";
                411: expected_uart_byte = "=";
                424: expected_uart_byte = " ";
                425: expected_uart_byte = "B";
                426: expected_uart_byte = "3";
                427: expected_uart_byte = "=";
                440: expected_uart_byte = " ";
                441: expected_uart_byte = "B";
                442: expected_uart_byte = "4";
                443: expected_uart_byte = "=";
                456: expected_uart_byte = " ";
                457: expected_uart_byte = "S";
                458: expected_uart_byte = "I";
                459: expected_uart_byte = "3";
                460: expected_uart_byte = "=";
                469: expected_uart_byte = " ";
                470: expected_uart_byte = "S";
                471: expected_uart_byte = "P";
                472: expected_uart_byte = "3";
                473: expected_uart_byte = "=";
                482: expected_uart_byte = " ";
                483: expected_uart_byte = "S";
                484: expected_uart_byte = "I";
                485: expected_uart_byte = "I";
                486: expected_uart_byte = "3";
                487: expected_uart_byte = "=";
                496: expected_uart_byte = " ";
                497: expected_uart_byte = "S";
                498: expected_uart_byte = "I";
                499: expected_uart_byte = "P";
                500: expected_uart_byte = "3";
                501: expected_uart_byte = "=";
                510: expected_uart_byte = " ";
                511: expected_uart_byte = "S";
                512: expected_uart_byte = "I";
                513: expected_uart_byte = "4";
                514: expected_uart_byte = "=";
                523: expected_uart_byte = " ";
                524: expected_uart_byte = "S";
                525: expected_uart_byte = "P";
                526: expected_uart_byte = "4";
                527: expected_uart_byte = "=";
                536: expected_uart_byte = " ";
                537: expected_uart_byte = "S";
                538: expected_uart_byte = "I";
                539: expected_uart_byte = "I";
                540: expected_uart_byte = "4";
                541: expected_uart_byte = "=";
                550: expected_uart_byte = " ";
                551: expected_uart_byte = "S";
                552: expected_uart_byte = "I";
                553: expected_uart_byte = "P";
                554: expected_uart_byte = "4";
                555: expected_uart_byte = "=";
                564: expected_uart_byte = 8'h0d;
                565: expected_uart_byte = 8'h0a;
                default: expected_uart_byte = 8'h0a;
            endcase
        end
    endfunction

    function is_hex_ascii;
        input [7:0] value;
        begin
            is_hex_ascii = ((value >= "0") && (value <= "9")) ||
                           ((value >= "A") && (value <= "F"));
        end
    endfunction

    initial begin
        byte_count = 0;
        sim_first_sum_a = 0;
        sim_first_sum_b = 0;
        sim_first_sum_seen = 0;
        sim_first_a_value = 0;
        sim_first_b_value = 0;
        sim_first_coeff_seen = 0;
        @(negedge uart_tx);
        forever begin
            #(BIT_NS * 3 / 2);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                received_byte[bit_index] = uart_tx;
                #BIT_NS;
            end
            if (uart_tx !== 1'b1) $fatal(1, "UART stop bit low");
            $write("%c", received_byte);
            if (((byte_count >= 39) && (byte_count <= 50)) ||
                ((byte_count >= 54) && (byte_count <= 65)) ||
                ((byte_count >= 70) && (byte_count <= 77)) ||
                ((byte_count >= 82) && (byte_count <= 89)) ||
                ((byte_count >= 95) && (byte_count <= 102)) ||
                ((byte_count >= 108) && (byte_count <= 115)) ||
                (byte_count == 119) ||
                ((byte_count >= 124) && (byte_count <= 139)) ||
                ((byte_count >= 144) && (byte_count <= 159)) ||
                ((byte_count >= 164) && (byte_count <= 179)) ||
                ((byte_count >= 184) && (byte_count <= 199)) ||
                ((byte_count >= 204) && (byte_count <= 219)) ||
                ((byte_count >= 224) && (byte_count <= 239)) ||
                ((byte_count >= 244) && (byte_count <= 259)) ||
                ((byte_count >= 264) && (byte_count <= 279)) ||
                ((byte_count >= 284) && (byte_count <= 299)) ||
                ((byte_count >= 304) && (byte_count <= 319)) ||
                ((byte_count >= 324) && (byte_count <= 339)) ||
                ((byte_count >= 344) && (byte_count <= 359)) ||
                ((byte_count >= 364) && (byte_count <= 375)) ||
                ((byte_count >= 380) && (byte_count <= 391)) ||
                ((byte_count >= 396) && (byte_count <= 407)) ||
                ((byte_count >= 412) && (byte_count <= 423)) ||
                ((byte_count >= 428) && (byte_count <= 439)) ||
                ((byte_count >= 444) && (byte_count <= 455)) ||
                ((byte_count >= 461) && (byte_count <= 468)) ||
                ((byte_count >= 474) && (byte_count <= 481)) ||
                ((byte_count >= 488) && (byte_count <= 495)) ||
                ((byte_count >= 502) && (byte_count <= 509)) ||
                ((byte_count >= 515) && (byte_count <= 522)) ||
                ((byte_count >= 528) && (byte_count <= 535)) ||
                ((byte_count >= 542) && (byte_count <= 549)) ||
                ((byte_count >= 556) && (byte_count <= 563))) begin
                if (!is_hex_ascii(received_byte))
                    $fatal(1, "UART diagnostic byte %0d is not hex: %02x",
                           byte_count, received_byte);
            end else if (received_byte !== expected_uart_byte(byte_count))
                $fatal(1, "UART byte %0d: expected %02x got %02x",
                       byte_count, expected_uart_byte(byte_count), received_byte);
            byte_count = byte_count + 1;
            if (received_byte == 8'h0a) begin
                if (byte_count != 566) $fatal(1, "UART line length %0d", byte_count);
                #(BIT_NS * 3);
                if (dut.failed || !dut.passed || dut.output_digest != 32'h69B9F759)
                    $fatal(1, "self-test state/digest mismatch failed=%0d passed=%0d digest=%08x",
                           dut.failed, dut.passed, dut.output_digest);
                if (dut.state != dut.ST_DONE || dbg_uart !== 1'b1)
                    $fatal(1, "self-test did not finish cleanly");
                if (dut.first_quotient != 64'h00000000000053e5)
                    $fatal(1, "first quotient mismatch %016x", dut.first_quotient);
                if (dut.first_a_value != 48'h000000764791 ||
                    dut.first_b_value != 48'h0000400dd9ae)
                    $fatal(1, "first coefficient mismatch A=%012x B=%012x",
                           dut.first_a_value, dut.first_b_value);
                if (dut.first_a_value != sim_first_a_value ||
                    dut.first_b_value != sim_first_b_value)
                    $fatal(1, "board-report taps differ from first coefficients");
                if (dut.second_q_numerator != 64'h00000000400DD9AE ||
                    dut.second_q_denominator != 64'd8 ||
                    dut.second_q_quotient != 64'h00000000400DD9AE)
                    $fatal(1, "first B-divider snapshot mismatch QMAG=%016x REM=%016x Q=%016x",
                           dut.second_q_numerator, dut.second_q_denominator,
                           dut.second_q_quotient);
                if (dut.first_sum_i != 32'd570 || dut.first_sum_p != 32'd215000 ||
                    dut.first_sum_ii != 32'd37986 || dut.first_sum_ip != 32'd13844000)
                    $fatal(1, "first input window sums mismatch SI=%08x SP=%08x SII=%08x SIP=%08x",
                           dut.first_sum_i, dut.first_sum_p,
                           dut.first_sum_ii, dut.first_sum_ip);
                if (dut.a3_sum_i != 32'd609 || dut.a3_sum_p != 32'd196000 ||
                    dut.a3_sum_ii != 32'd44625 || dut.a3_sum_ip != 32'd13918000 ||
                    dut.a4_sum_i != 32'd707 || dut.a4_sum_p != 32'd153000 ||
                    dut.a4_sum_ii != 32'd63747 || dut.a4_sum_ip != 32'd11550000)
                    $fatal(1, "A_SOLVE windows mismatch A3=%08x/%08x/%08x/%08x A4=%08x/%08x/%08x/%08x",
                           dut.a3_sum_i, dut.a3_sum_p, dut.a3_sum_ii, dut.a3_sum_ip,
                           dut.a4_sum_i, dut.a4_sum_p, dut.a4_sum_ii, dut.a4_sum_ip);
                if (dut.frame_error_flags != 0)
                    $fatal(1, "input-frame error flags=%03b", dut.frame_error_flags);
                if (dut.first_a_numerator != 64'h0000001F38300000 ||
                    dut.first_a_denominator != 64'h0000000000004392 ||
                    dut.first_b_numerator != 64'h00000002407CA726 ||
                    dut.first_b_denominator != 64'd9)
                    $fatal(1, "first divide operands mismatch AN=%016x AD=%016x BN=%016x BD=%016x",
                           dut.first_a_numerator, dut.first_a_denominator,
                           dut.first_b_numerator, dut.first_b_denominator);
                if (sim_first_sum_a != 64'h00000000022bf36b ||
                    sim_first_sum_b != 64'h00000002751e8a56)
                    $fatal(1, "first coefficient sums mismatch");
                $display("DEHAZE_GUIDED_SELFTEST_SIM PASS bytes=%0d digest=%08x q=%016x a0=%012x b0=%012x si=%08x sp=%08x sii=%08x sip=%08x an=%016x ad=%016x bn=%016x bd=%016x q1n=%016x q1d=%016x q1q=%016x sa=%016x sb=%016x q0n=%016x q0d=%016x q0q=%016x a1=%012x a3=%012x a4=%012x b1=%012x b3=%012x b4=%012x a3win=%08x/%08x/%08x/%08x a4win=%08x/%08x/%08x/%08x",
                         byte_count, dut.output_digest, dut.first_quotient,
                         sim_first_a_value, sim_first_b_value, dut.first_sum_i,
                         dut.first_sum_p, dut.first_sum_ii, dut.first_sum_ip,
                         dut.first_a_numerator, dut.first_a_denominator,
                         dut.first_b_numerator, dut.first_b_denominator,
                         dut.second_q_numerator, dut.second_q_denominator,
                         dut.second_q_quotient, dut.first_q_sum_a,
                         dut.first_q_sum_b, dut.first_q_numerator,
                         dut.first_q_denominator, dut.first_quotient,
                         dut.a_coeff_1, dut.a_coeff_3, dut.a_coeff_4,
                          dut.b_coeff_1, dut.b_coeff_3, dut.b_coeff_4,
                          dut.a3_sum_i, dut.a3_sum_p, dut.a3_sum_ii, dut.a3_sum_ip,
                          dut.a4_sum_i, dut.a4_sum_p, dut.a4_sum_ii, dut.a4_sum_ip);
                $finish;
            end
            @(negedge uart_tx);
        end
    end

    initial begin
        // 566-byte diagnostic UART line takes about 49.2 ms at 115200 baud.
        #60_000_000;
        $fatal(1, "dehaze guided board self-test timed out");
    end
endmodule
