`timescale 1ns/1ps
// Cycle-level check of the 25K transport probe at the dock clock: 50 MHz,
// UART 115200 8N1, XOR A5 echo.  The nonce list is dumped so the run log shows
// exactly which bytes were injected; the board rounds use fresh random lists.
module tb_transport_probe_25k;
    localparam integer BITNS = 8681;      // one bit at 115200
    localparam integer NBYTES = 96;

    reg clk = 0, rx_pin = 1;
    wire tx_pin, dbg_uart;
    integer si, di, got, bad, fdn, fde;
    reg [7:0] inb [0:NBYTES-1];
    reg [7:0] shift;

    transport_probe_25k #(.CLK_FRE(50)) dut (.clk(clk), .uart_rx_pin(rx_pin),
        .uart_tx(tx_pin), .dbg_uart(dbg_uart));
    always #10 clk = ~clk;                // 20 ns period = 50 MHz

    task send_byte(input [7:0] b);
        integer k;
        begin
            rx_pin = 0; #BITNS;
            for (k = 0; k < 8; k = k + 1) begin rx_pin = b[k]; #BITNS; end
            rx_pin = 1; #BITNS;           // stop bit
        end
    endtask

    initial begin
        for (si = 0; si < NBYTES; si = si + 1) inb[si] = $urandom;
        fdn = $fopen("nonce.bin", "w");
        for (si = 0; si < NBYTES; si = si + 1) $fwrite(fdn, "%02x\n", inb[si]);
        $fclose(fdn);
        fde = $fopen("echo.bin", "w");
        wait (dut.rst_n === 1'b1);        // POR counts 65536 cycles = 1.31 ms
        #300;
        for (si = 0; si < NBYTES; si = si + 1) begin
            send_byte(inb[si]);
            // The echo takes one byte time (86.8 us); injecting faster would
            // legitimately overflow the receiver's single holding register.
            #100_000;
        end
    end

    // decode the DUT's TX line independently of the DUT's own FSM
    initial begin
        bad = 0; got = 0;
        wait (dut.rst_n === 1'b1);        // armed before the first byte is sent
        #50;
        forever begin
            @(negedge tx_pin);
            #(BITNS + BITNS / 2);
            shift = 8'h00;
            for (di = 0; di < 8; di = di + 1) begin
                shift = {tx_pin, shift[7:1]};
                #(BITNS);
            end
            if (tx_pin !== 1'b1) begin
                $display("FRAMING ERROR at byte %0d", got);
                bad = bad + 1;
            end else begin
                if (got < NBYTES && shift !== (inb[got] ^ 8'ha5)) bad = bad + 1;
                $fwrite(fde, "%02x\n", shift);
                got = got + 1;
            end
            #(BITNS / 2);
        end
    end

    initial begin
        #60_000_000;
        $display("TRANSPORT SIM got=%0d bad=%0d", got, bad);
        // a string ternary would print as a packed decimal number, not a label
        if (got == NBYTES && bad == 0) $display("TRANSPORT SIM PASS");
        else $display("TRANSPORT SIM FAIL");
        $fclose(fde);
        $finish;
    end
endmodule
