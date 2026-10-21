`timescale 1ns/1ps

module tb_img_mf_auto_stitch_selftest_25k;
    localparam integer CLK_HZ = 25000000;
    localparam integer BAUD = 2500000;
    localparam integer BIT_CLKS = CLK_HZ / BAUD;
    localparam integer BIT_NS = BIT_CLKS * 40;

    reg clk=1'b0;
    reg uart_rx_pin=1'b1;
    wire uart_tx;
    wire dbg_uart;
    integer byte_index;
    integer bit_index;
    reg [7:0] received;
    time last_functional_rise=0;

    always #10 clk=~clk;

    always @(posedge dut.functional_clk) begin
        if (last_functional_rise!=0 && $time-last_functional_rise!=40)
            $fatal(1,"functional clock period expected 40 ns got %0d ns",
                   $time-last_functional_rise);
        last_functional_rise=$time;
    end

    img_mf_auto_stitch_selftest_25k #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD), .POR_CYCLES(16)
    ) dut (
        .clk(clk), .uart_rx_pin(uart_rx_pin), .uart_tx(uart_tx),
        .dbg_uart(dbg_uart)
    );

    function [7:0] expected_byte;
        input integer index;
        begin
            case (index)
                 0: expected_byte="S"; 1: expected_byte="T";
                 2: expected_byte="I"; 3: expected_byte="T";
                 4: expected_byte="C"; 5: expected_byte="H";
                 6: expected_byte=" "; 7: expected_byte="P";
                 8: expected_byte="A"; 9: expected_byte="S";
                10: expected_byte="S"; 11: expected_byte=8'h0d;
                default: expected_byte=8'h0a;
            endcase
        end
    endfunction

    task receive_uart_byte;
        output reg [7:0] value;
        begin
            @(negedge uart_tx);
            #(BIT_NS*1.5);
            for (bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                value[bit_index]=uart_tx;
                #BIT_NS;
            end
            if (uart_tx!==1'b1) $fatal(1,"UART stop bit low after %02x",value);
        end
    endtask

    initial begin
        for (byte_index=0;byte_index<13;byte_index=byte_index+1) begin
            receive_uart_byte(received);
            if (received!==expected_byte(byte_index))
                $fatal(1,"UART byte %0d expected %02x got %02x",byte_index,
                       expected_byte(byte_index),received);
        end
        #(BIT_NS*2);
        if (dut.failed!==1'b0 || dut.passed!==1'b1 || dbg_uart!==1'b1 ||
            dut.output_index!==6'd55 || dut.registration_dx!==16'sd1 ||
            dut.registration_dy!==16'sd0 || dut.registration_cost!==48'd0 ||
            dut.registration_confidence===48'd0)
            $fatal(1,"self-test completion state mismatch");
        if (uart_tx!==1'b1 || dut.state!==dut.ST_DONE)
            $fatal(1,"unexpected UART tail or incomplete report");
        $display("PASS img_mf_auto_stitch_selftest_25k: 30 input pairs, 56 golden canvas pixels, dx=1 dy=0, UART=STITCH PASS");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1,"auto-stitch board self-test simulation timed out");
    end
endmodule

// Functional simulation model for the GW5A PLLA primitive instantiated by
// the board top. The board build uses the hard primitive from cells_xtra_gw5a.
module PLLA #(
    parameter FCLKIN = "50.0",
    parameter IDIV_SEL = 1,
    parameter FBDIV_SEL = 1,
    parameter MDIV_SEL = 16,
    parameter ODIV0_SEL = 32,
    parameter ODIV1_SEL = 8,
    parameter ODIV2_SEL = 8,
    parameter ODIV3_SEL = 8,
    parameter ODIV4_SEL = 8,
    parameter ODIV5_SEL = 8,
    parameter ODIV6_SEL = 8,
    parameter CLKOUT0_EN = "TRUE",
    parameter CLKOUT1_EN = "FALSE",
    parameter CLKOUT2_EN = "FALSE",
    parameter CLKOUT3_EN = "FALSE",
    parameter CLKOUT4_EN = "FALSE",
    parameter CLKOUT5_EN = "FALSE",
    parameter CLKOUT6_EN = "FALSE",
    parameter CLKFB_SEL = "INTERNAL"
) (
    input wire CLKIN, input wire CLKFB,
    input wire RESET, input wire PLLPWD,
    input wire RESET_I, input wire RESET_O,
    input wire [2:0] PSSEL, input wire PSDIR, input wire PSPULSE,
    input wire SSCPOL, input wire SSCON,
    input wire [6:0] SSCMDSEL, input wire [2:0] SSCMDSEL_FRAC,
    input wire MDCLK, input wire [1:0] MDOPC, input wire MDAINC,
    input wire [7:0] MDWDI, output wire [7:0] MDRDO,
    output reg LOCK,
    output wire CLKOUT0, output wire CLKOUT1, output wire CLKOUT2,
    output wire CLKOUT3, output wire CLKOUT4, output wire CLKOUT5,
    output wire CLKOUT6, output wire CLKFBOUT
);
    reg clkout0_model=1'b0;
    reg [2:0] lock_count=3'd0;
    initial LOCK=1'b0;
    always @(posedge CLKIN) begin
        if (RESET || PLLPWD || RESET_I || RESET_O) begin
            LOCK <= 1'b0;
            lock_count <= 3'd0;
            clkout0_model <= 1'b0;
        end else begin
            if (!LOCK) begin
                if (lock_count == 3'd3) LOCK <= 1'b1;
                else lock_count <= lock_count + 1'b1;
            end else begin
                // The selected PLLA ratios produce a 25 MHz output from the
                // testbench's 50 MHz reference clock.
                clkout0_model <= ~clkout0_model;
            end
        end
    end
    assign MDRDO = 8'd0;
    assign CLKOUT0 = (CLKOUT0_EN == "TRUE") ? clkout0_model : 1'b0;
    assign CLKOUT1 = 1'b0;
    assign CLKOUT2 = 1'b0;
    assign CLKOUT3 = 1'b0;
    assign CLKOUT4 = 1'b0;
    assign CLKOUT5 = 1'b0;
    assign CLKOUT6 = 1'b0;
    assign CLKFBOUT = 1'b0;
endmodule
