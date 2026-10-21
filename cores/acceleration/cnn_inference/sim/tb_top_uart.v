// Full-loop UART testbench for cores/acceleration/cnn_inference/src/top.v.
//
// Bit-bangs 115200 8N1 into the ANDed rx pins (all four driven together in
// the tb), decodes the TX stream, and checks:
//   - boot banner "CNN138K BOOT D=<digest> C=<dec>" with D == golden digest
//   - PING  -> A5 01 '1' '3' '8' 'K'
//   - LOAD  -> A5 02 00   (784-byte mem/img.mem image)
//   - RUN   -> A5 03 00
//   - STAT  -> st.done set
//   - RESC  -> scores == mem/exp_scores.mem, digest == f0981d37
// Prints "TOPUART PASS D=<8hex>" or "TOPUART FAIL ...".
//
// $readmemh paths are relative to the repo root (test script runs vvp from
// D:\sipeedTANG20K, same convention as cnn_engine.v). Override with
// -DIMG_MEM/-DEXP_MEM.

`timescale 1ns/1ps

`ifndef IMG_MEM
`define IMG_MEM "cores/acceleration/cnn_inference/mem/img.mem"
`endif
`ifndef EXP_MEM
`define EXP_MEM "cores/acceleration/cnn_inference/mem/exp_scores.mem"
`endif

module tb_top_uart;

    localparam integer BIT = 8680;          // ns per bit @115200 (~434*20)
    localparam [31:0] GOLD_DIGEST = 32'hf0981d37;

    reg  clk = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    reg        rst = 1'b0;                  // reads LOW on bare SOM
    reg        rxd = 1'b1;                  // idle-high UART line
    wire [5:0] led;
    wire       tx_p15, tx_u16, tx_v22;

    top dut (
        .clk(clk), .rst(rst), .led(led),
        .uart_tx_p15(tx_p15), .uart_tx_u16(tx_u16), .uart_tx_v22(tx_v22),
        .uart_rx(rxd)
    );

    // ---------------------------------------------------------------
    // host -> DUT byte
    // ---------------------------------------------------------------
    task tx_byte;
        input [7:0] b;
        integer i;
        begin
            rxd = 1'b0; #(BIT);             // start
            for (i = 0; i < 8; i = i + 1) begin
                rxd = b[i]; #(BIT);
            end
            rxd = 1'b1; #(BIT);             // stop
        end
    endtask

    // ---------------------------------------------------------------
    // DUT -> host byte capture (runs continuously)
    // ---------------------------------------------------------------
    reg [7:0] cap  [0:8191];
    integer   capn = 0;
    reg [7:0] capb;

    task rx_byte;
        output [7:0] b;
        integer i;
        begin
            @(negedge tx_p15);              // start edge
            #(BIT/2);                       // center of start bit
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT); b[i] = tx_p15;
            end
            #(BIT);                         // center of stop bit
        end
    endtask

    initial begin : CAPTURE
        forever begin
            rx_byte(capb);
            cap[capn] = capb;
            capn      = capn + 1;
        end
    end

    function [3:0] hexval;
        input [7:0] c;
        begin
            if      (c >= "0" && c <= "9") hexval = c - "0";
            else if (c >= "A" && c <= "F") hexval = c - "A" + 10;
            else if (c >= "a" && c <= "f") hexval = c - "a" + 10;
            else                           hexval = 4'h0;
        end
    endfunction

    // ---------------------------------------------------------------
    // stimulus + checks
    // ---------------------------------------------------------------
    reg [7:0]  img   [0:1023];
    reg [31:0] exps  [0:15];
    integer    errors = 0;
    integer    i, base, polls;
    reg [31:0] got, got_digest, got_cycles;

    task check;
        input cond;
        input [255:0] what;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("TOPUART FAIL: %0s (t=%0t)", what, $time);
            end
        end
    endtask

    initial begin
        $readmemh(`IMG_MEM, img);
        $readmemh(`EXP_MEM, exps);

        // -------- boot banner: "CNN138K BOOT D=XXXXXXXX C=NNNNNN\r\n" (34B)
        wait (capn >= 34);
        check(cap[0]  == "C" && cap[1]  == "N" && cap[2]  == "N" &&
              cap[3]  == "1" && cap[4]  == "3" && cap[5]  == "8" &&
              cap[6]  == "K" && cap[8]  == "B" && cap[13] == "D" &&
              cap[14] == "=",
              "boot banner header");
        got = 0;
        for (i = 0; i < 8; i = i + 1)
            got = {got[27:0], hexval(cap[15+i])};
        check(got == GOLD_DIGEST, "boot banner digest");
        check(cap[24] == "C" && cap[25] == "=" &&
              cap[32] == 8'd13 && cap[33] == 8'd10,
              "boot banner trailer");
        $display("TOPUART: boot line ok, D=%08x C=%c%c%c%c%c%c",
                 got, cap[26], cap[27], cap[28], cap[29], cap[30], cap[31]);

        // -------- PING -> A5 01 '1' '3' '8' 'K'
        base = capn;
        tx_byte(8'h01);
        wait (capn >= base + 6);
        check(cap[base]   == 8'hA5 && cap[base+1] == 8'h01 &&
              cap[base+2] == "1"  && cap[base+3] == "3"   &&
              cap[base+4] == "8"  && cap[base+5] == "K",
              "PING response");

        // -------- LOAD 784-byte image -> A5 02 00
        base = capn;
        tx_byte(8'h02);
        tx_byte(8'h10);                     // ll = 784 & 0xff
        tx_byte(8'h03);                     // hh = 784 >> 8
        for (i = 0; i < 784; i = i + 1)
            tx_byte(img[i]);
        wait (capn >= base + 3);
        check(cap[base] == 8'hA5 && cap[base+1] == 8'h02 &&
              cap[base+2] == 8'h00,
              "LOAD response");

        // -------- RUN -> A5 03 00
        base = capn;
        tx_byte(8'h03);
        wait (capn >= base + 3);
        check(cap[base] == 8'hA5 && cap[base+1] == 8'h03 &&
              cap[base+2] == 8'h00,
              "RUN response");

        // -------- poll STAT until done (st bit1)
        polls = 0;
        got   = 0;
        while (polls < 200 && got[1] == 1'b0) begin
            base = capn;
            tx_byte(8'h04);
            wait (capn >= base + 7);
            check(cap[base] == 8'hA5 && cap[base+1] == 8'h04,
                  "STAT response header");
            got = {24'd0, cap[base+2]};     // status byte -> check bit1
            polls = polls + 1;
        end
        check(polls < 200, "STAT done poll");
        $display("TOPUART: done after %0d STAT poll(s)", polls);

        // -------- RESC -> A5 05 <40B scores> <4B digest> <4B cycles>
        base = capn;
        tx_byte(8'h05);
        wait (capn >= base + 50);
        check(cap[base] == 8'hA5 && cap[base+1] == 8'h05,
              "RESC response header");
        for (i = 0; i < 10; i = i + 1) begin
            got = {cap[base+2+4*i+3], cap[base+2+4*i+2],
                   cap[base+2+4*i+1], cap[base+2+4*i+0]};
            if (got !== exps[i]) begin
                errors = errors + 1;
                $display("TOPUART FAIL: score[%0d]=%08x exp %08x",
                         i, got, exps[i]);
            end
        end
        got_digest = {cap[base+45], cap[base+44], cap[base+43], cap[base+42]};
        got_cycles = {cap[base+49], cap[base+48], cap[base+47], cap[base+46]};
        check(got_digest == GOLD_DIGEST, "RESC digest");
        $display("TOPUART: RESC received, digest=%08x cycles=%0d",
                 got_digest, got_cycles);

        // -------- DUMP 4 img bytes (rd_sel=3, addr 0, len 4) -> A5 06 <4B>
        base = capn;
        tx_byte(8'h06);
        tx_byte(8'h03);                     // ss = img
        tx_byte(8'h00); tx_byte(8'h00);     // addr = 0
        tx_byte(8'h04); tx_byte(8'h00);     // len  = 4
        wait (capn >= base + 6);
        check(cap[base] == 8'hA5 && cap[base+1] == 8'h06,
              "DUMP response header");
        for (i = 0; i < 4; i = i + 1) begin
            if (cap[base+2+i] !== img[i]) begin
                errors = errors + 1;
                $display("TOPUART FAIL: dump[%0d]=%02x exp %02x",
                         i, cap[base+2+i], img[i]);
            end
        end

        // -------- verdict
        if (errors == 0)
            $display("TOPUART PASS D=%08x", got_digest);
        else
            $display("TOPUART FAIL errors=%0d", errors);
        $finish;
    end

    // global timeout (~1 s of sim time; LOAD alone is ~70 ms)
    initial begin
        #1000000000;
        $display("TOPUART FAIL timeout (capn=%0d)", capn);
        $finish;
    end

endmodule
