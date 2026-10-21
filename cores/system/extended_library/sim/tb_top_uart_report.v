`timescale 1ns/1ps
// ============================================================================
// tb_top_uart_report -- capture the board-top UART report byte stream and
// byte-compare it against sim/expected_report_<mask>.mem (produced by
// tools/gen_report_golden.py from the unit EXP digests -- independent source).
// ============================================================================
module tb_top_uart_report;
`ifdef MASK_HEX
    parameter [39:0] MASK = `MASK_HEX;
`else
    parameter [39:0] MASK = 40'hFF_FF_FF_FF_FF;
`endif
    parameter EXPECT = "expected_report.mem";
    localparam integer MSG_LEN = 41 * 32;
    localparam integer BIT_NS  = 8680;        // 115200 baud ~ 8.68 us

    reg clk = 1'b0;
    always #5 clk = ~clk;

    wire uart_tx, status_pass, status_fail;
    top #(.UNIT_EN(MASK)) dut (
        .clk(clk), .uart_tx(uart_tx),
        .status_pass(status_pass), .status_fail(status_fail));

    reg [7:0] exp [0:MSG_LEN-1];
    reg [7:0] cap [0:MSG_LEN-1];
    integer capn = 0;
    integer errs = 0;
    integer i;

    initial $readmemh(EXPECT, exp);

    // UART byte capture on the TX pin
    task capture_byte;
        integer b;
        reg [7:0] v;
        begin
            #(BIT_NS/2);                       // mid start bit
            if (uart_tx !== 1'b0) begin errs = errs + 1; end
            for (b = 0; b < 8; b = b + 1) begin
                #BIT_NS;
                v[b] = uart_tx;
            end
            #BIT_NS;                           // stop bit
            if (capn < MSG_LEN) cap[capn] = v;
            capn = capn + 1;
        end
    endtask

    initial begin
        // wait for report start: uart_tx low = start bit of 'W'
        wait (status_pass === 1'b1 || status_fail === 1'b1);
        // catch first start bit
        wait (uart_tx === 1'b0);
        while (capn < MSG_LEN) capture_byte;
        for (i = 0; i < MSG_LEN; i = i + 1) begin
            if (cap[i] !== exp[i]) begin
                errs = errs + 1;
                if (errs < 24)
                    $display("UART MISM idx=%0d got=%02x(%c) exp=%02x(%c)",
                             i, cap[i], cap[i], exp[i], exp[i]);
            end
        end
        if (errs == 0 && status_pass === 1'b1)
            $display("W2TB UARTREP PASS M=%010x", MASK);
        else
            $display("W2TB UARTREP FAIL M=%010x errs=%0d", MASK, errs);
        $finish;
    end

    initial begin
        #2000000000;                           // 2 s guard
        $display("W2TB UARTREP FAIL timeout capn=%0d", capn);
        $finish;
    end
endmodule
