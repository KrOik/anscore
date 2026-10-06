`timescale 1ns/1ps
// Testbench for the Tang Primer 20K SD-card SPI reader.
// Emulates an SDHC card in SPI mode (CMD0/CMD8/ACMD41/CMD58/CMD17) holding a
// FAT16 image: MBR at LBA0 with partition 1 at LBA 2048, a FAT16 BPB, a root
// directory containing "TEST    TXT" (cluster 2, 32 bytes), and known file
// data.  Decodes the DUT UART stream and checks every expected report line.
module tb_sdcard;

    // ------------------------------------------------------------------
    // clock / reset
    // ------------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #18.5 clk = ~clk;   // ~27 MHz

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    wire sd_clk, sd_mosi, sd_cs_n, uart_tx_pin;
    reg  sd_det = 1'b0;
    wire sd_miso;

    top #(.BOOT_DELAY(2000)) dut (
        .clk(clk), .rst_n(rst_n),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n), .sd_det(sd_det),
        .uart_tx_pin(uart_tx_pin)
    );

    // ------------------------------------------------------------------
    // SD card model (SPI slave, behavioral)
    // ------------------------------------------------------------------
    localparam integer MEM_BYTES = 4096 * 512;
    reg [7:0] cardmem [0:MEM_BYTES-1];

    reg        miso_r = 1'b1;
    reg [7:0]  miso_cur = 8'hFF;
    reg [7:0]  rx_shift = 8'd0;
    integer    bit_cnt = 0;

    reg [7:0]  q [0:1023];
    integer    qh = 0, qt = 0;

    reg [7:0]  cur_cmd;
    reg [31:0] cur_arg;
    integer    arg_left = 0;   // bytes still expected: 4 arg + 1 crc
    reg        in_cmd = 0;
    integer    ac41_n = 0;
    integer    rd_lba_m;
    integer    di;

    assign sd_miso = sd_cs_n ? 1'b1 : miso_r;

    task push(input [7:0] b);
        begin
            q[qt] = b;
            qt = qt + 1;
        end
    endtask

    task push_sector(input integer lba);
        integer k;
        begin
            for (k = 0; k < 512; k = k + 1)
                push(cardmem[lba * 512 + k]);
        end
    endtask

    // CRC16-CCITT (poly 0x1021, init 0) over one 512-byte sector, matching
    // what spirxdata verifies on the trailing two CRC bytes.
    function [15:0] crc16_sector(input integer lba);
        integer k, b;
        reg [15:0] c;
        begin
            c = 16'd0;
            for (k = 0; k < 512; k = k + 1) begin
                c = c ^ (cardmem[lba * 512 + k] << 8);
                for (b = 0; b < 8; b = b + 1)
                    c = c[15] ? (c << 1) ^ 16'h1021 : (c << 1);
            end
            crc16_sector = c;
        end
    endfunction

    // decide the response once a full command (cmd+arg+crc) arrived
    task command_done;
        begin
            $display("[card] cmd=%0d arg=%08x t=%0t", cur_cmd, cur_arg, $time);
            case (cur_cmd)
                8'd0:  push(8'h01);                          // CMD0 idle
                8'd8:  begin                                 // CMD8
                    push(8'h01);
                    push(8'h00); push(8'h00);
                    push(8'h01); push(8'hAA);
                end
                8'd16: push(8'h00);                          // CMD16
                8'd17: begin                                 // CMD17 read
                    push(8'h00);
                    push(8'hFF); push(8'hFE);
                    push_sector(cur_arg);                    // HC: block addr
                    push(crc16_sector(cur_arg) >> 8);        // CRC16 hi
                    push(crc16_sector(cur_arg) & 8'hFF);     // CRC16 lo
                end
                8'd41: begin                                 // ACMD41
                    if (ac41_n < 2) push(8'h01);
                    else push(8'h00);
                    ac41_n = ac41_n + 1;
                end
                8'd55: push(8'h01);                          // CMD55
                8'd58: begin                                 // CMD58 OCR
                    push(8'h00);
                    push(8'hC0); push(8'hFF);
                    push(8'h80); push(8'h00);
                end
                default: push(8'h05);                        // illegal
            endcase
        end
    endtask

    // byte-level processing at each completed host->card byte
    task byte_done(input [7:0] b);
        begin
            if (!in_cmd && b[7:6] == 2'b01) begin  // command byte 0x40|cmd
                cur_cmd  = b[5:0];
                cur_arg  = 32'd0;
                arg_left = 5;
                in_cmd   = 1;
            end else if (in_cmd) begin
                if (arg_left == 5 || arg_left > 1) begin
                    cur_arg = {cur_arg[23:0], b};
                    arg_left = arg_left - 1;
                end else begin               // crc byte
                    arg_left = 0;
                    in_cmd = 0;
                    command_done;
                end
            end
        end
    endtask

    integer sess_edges = 0;
    always @(sd_cs_n) $display("[cs] -> %b t=%0t", sd_cs_n, $time);
    always @(posedge sd_clk) if (!sd_cs_n) sess_edges = sess_edges + 1;
    always @(posedge sd_cs_n) begin
        $display("[card] cs high: sess_edges=%0d t=%0t", sess_edges, $time);
        sess_edges = 0;
    end
    always @(negedge sd_cs_n)
        $display("[card] cs low t=%0t sck=%b", $time, sd_clk);

    // capture MOSI on rising edges; shift MISO on falling edges
    always @(posedge sd_clk or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            bit_cnt  <= 0;
            rx_shift <= 8'd0;
            in_cmd   <= 0;
            arg_left <= 0;
        end else begin
            rx_shift <= {rx_shift[6:0], sd_mosi};
            if (bit_cnt == 7) begin
                bit_cnt <= 0;
                $display("[card] rx=%02x t=%0t", {rx_shift[6:0], sd_mosi}, $time);
                byte_done({rx_shift[6:0], sd_mosi});
                if (qt > qh) begin
                    miso_cur <= q[qh];
                    qh = qh + 1;
                end else begin
                    miso_cur <= 8'hFF;
                end
            end else begin
                bit_cnt <= bit_cnt + 1;
            end
        end
    end

    always @(negedge sd_clk or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            miso_r   <= 1'b1;
            miso_cur <= 8'hFF;
            qh <= 0;
            qt <= 0;
        end else begin
            miso_r   <= miso_cur[7];
            miso_cur <= {miso_cur[6:0], 1'b1};
        end
    end

    // ------------------------------------------------------------------
    // FAT16 card image
    // ------------------------------------------------------------------
    task w8(input integer a, input [7:0] v);
        cardmem[a] = v;
    endtask
    task w16(input integer a, input [15:0] v);
        begin cardmem[a] = v[7:0]; cardmem[a+1] = v[15:8]; end
    endtask
    task w32(input integer a, input [31:0] v);
        begin
            cardmem[a]   = v[7:0];   cardmem[a+1] = v[15:8];
            cardmem[a+2] = v[23:16]; cardmem[a+3] = v[31:24];
        end
    endtask

    localparam integer P1 = 2048;            // partition 1 LBA
    localparam integer ROOT_LBA = 2048 + 1 + 2*32;   // 2113
    localparam integer DATA_LBA = 2113 + 32;         // 2145 (cluster 2)
    reg [8*32-1:0] file_text = "HELLO_TANG_PRIMER_20K_SDCARD_XXX";
    integer fi;

    reg gpt_mode;
    initial begin
        gpt_mode = $test$plusargs("GPT");
        for (fi = 0; fi < MEM_BYTES; fi = fi + 1) cardmem[fi] = 8'd0;

        // ---- MBR at LBA 0 ------------------------------------------
        cardmem[446+0]  = 8'h00;             // boot flag
        if (gpt_mode) begin
            cardmem[446+4]  = 8'hEE;         // type: GPT protective
            w32(446+8,  1);                  // covers whole disk
            w32(446+12, MEM_BYTES/512 - 1);
        end else begin
            cardmem[446+4]  = 8'h06;         // type: FAT16
            w32(446+8,  P1);                 // LBA start
            w32(446+12, 4096);               // sector count
        end
        cardmem[510] = 8'h55; cardmem[511] = 8'hAA;

        if (gpt_mode) begin
            // ---- GPT header at LBA 1 ---------------------------------
            cardmem[512+0] = "E"; cardmem[512+1] = "F";
            cardmem[512+2] = "I"; cardmem[512+3] = " ";
            cardmem[512+4] = "P"; cardmem[512+5] = "A";
            cardmem[512+6] = "R"; cardmem[512+7] = "T";
            w32(512+32'h48, 2);              // partition entries at LBA 2
            w32(512+32'h50, 128);            // num entries
            w32(512+32'h54, 128);            // entry size
            // ---- GPT entries at LBA 2: entry0 = ESP at LBA 2048 -------
            cardmem[1024+0] = 8'h28;         // type GUID nonzero
            cardmem[1024+1] = 8'h73;
            w32(1024+32'h20, P1);            // first LBA = 2048
            w32(1024+32'h28, P1+4095);       // last LBA
        end

        // ---- FAT16 boot sector at LBA 2048 --------------------------
        w8 (P1*512+0,  8'hEB); w8(P1*512+1, 8'h3C); w8(P1*512+2, 8'h90);
        w16(P1*512+11, 512);                 // bytes/sector
        w8 (P1*512+13, 4);                   // sectors/cluster
        w16(P1*512+14, 1);                   // reserved sectors
        w8 (P1*512+16, 2);                   // FAT count
        w16(P1*512+17, 512);                 // root entries
        w16(P1*512+19, 4096);                // total sectors (16b)
        w8 (P1*512+21, 8'hF8);               // media
        w16(P1*512+22, 32);                  // sectors per FAT
        cardmem[P1*512+510] = 8'h55; cardmem[P1*512+511] = 8'hAA;

        // ---- root directory at LBA 2113 -----------------------------
        // entry 0: "TEST    TXT", file attr, cluster 2, size 32
        cardmem[ROOT_LBA*512+0]  = "T"; cardmem[ROOT_LBA*512+1]  = "E";
        cardmem[ROOT_LBA*512+2]  = "S"; cardmem[ROOT_LBA*512+3]  = "T";
        cardmem[ROOT_LBA*512+4]  = " "; cardmem[ROOT_LBA*512+5]  = " ";
        cardmem[ROOT_LBA*512+6]  = " "; cardmem[ROOT_LBA*512+7]  = " ";
        cardmem[ROOT_LBA*512+8]  = "T"; cardmem[ROOT_LBA*512+9]  = "X";
        cardmem[ROOT_LBA*512+10] = "T";
        cardmem[ROOT_LBA*512+11] = 8'h20;             // archive
        w16(ROOT_LBA*512+26, 2);                      // first cluster
        w32(ROOT_LBA*512+28, 32);                     // size
        // entry 1: 0x00 = end of directory
        cardmem[ROOT_LBA*512+32] = 8'h00;

        // ---- file data: cluster 2 = LBA 2145 -------------------------
        for (fi = 0; fi < 32; fi = fi + 1)
            cardmem[DATA_LBA*512+fi] = file_text[8*(31-fi) +: 8];
    end

    // ------------------------------------------------------------------
    // UART receive monitor (115200 8N1)
    // ------------------------------------------------------------------
    localparam real BIT_NS = 1.0e9 * 234.0 / 27.0e6;  // DUT actual baud
    reg [7:0] rline [0:127];
    integer   rlen = 0;
    reg [7:0] rxb;
    integer   bi;

    reg [7:0] got [0:15][0:127];
    integer   glen [0:15];
    integer   nlines = 0;

    task store_line;
        integer k;
        begin
            for (k = 0; k < rlen; k = k + 1)
                got[nlines][k] = rline[k];
            glen[nlines] = rlen;
            nlines = nlines + 1;
            rlen = 0;
        end
    endtask

    initial begin : uart_mon
        forever begin
            @(negedge uart_tx_pin);
            #(BIT_NS / 2);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                #(BIT_NS);
                rxb[bi] = uart_tx_pin;
            end
            #(BIT_NS / 2);   // stop bit (half, to catch next start edge)
            if (rxb == 8'h0A) begin
                store_line;
            end else if (rxb != 8'h0D) begin
                rline[rlen] = rxb;
                rlen = rlen + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // expected report
    // ------------------------------------------------------------------
    reg [7:0] exp [0:15][0:127];
    integer   elen [0:15];
    integer   nexp = 0;
    integer   ei, ej;

    task setexp(input [8*112-1:0] s);
        integer l, k;
        begin
            // literal is right-justified: lowest byte = last char
            l = 0;
            while (l < 112 && s[8*l +: 8] != 8'h00) l = l + 1;
            elen[nexp] = l;
            for (k = 0; k < l; k = k + 1)
                exp[nexp][k] = s[8*(l-1-k) +: 8];
            nexp = nexp + 1;
        end
    endtask

    integer pass_cnt, fail_cnt;
    task check_line(input integer li);
        integer k; reg ok;
        begin
            ok = 1;
            if (glen[li] != elen[li]) ok = 0;
            else begin
                for (k = 0; k < elen[li]; k = k + 1)
                    if (got[li][k] !== exp[li][k]) ok = 0;
            end
            if (ok) begin
                pass_cnt = pass_cnt + 1;
                $display("line %0d OK", li);
            end else begin
                fail_cnt = fail_cnt + 1;
                $write("line %0d MISMATCH got='", li);
                for (k = 0; k < glen[li]; k = k + 1) $write("%c", got[li][k]);
                $write("' exp='");
                for (k = 0; k < elen[li]; k = k + 1) $write("%c", exp[li][k]);
                $display("'");
            end
        end
    endtask

    // ------------------------------------------------------------------
    // stimulus / checking
    // ------------------------------------------------------------------
    initial begin
        pass_cnt = 0; fail_cnt = 0;
        setexp("IN V=2 HC=1 D=0");
        setexp("MBR OK");
        if (gpt_mode) begin
            setexp("P1 T=EE L=00000001 S=00000FFF");
            setexp("P2 T=00 L=00000000 S=00000000");
            setexp("P3 T=00 L=00000000 S=00000000");
            setexp("P4 T=00 L=00000000 S=00000000");
            setexp("GP S=OK EL=00000002");
            setexp("GP L=00000800");
        end else begin
            setexp("P1 T=06 L=00000800 S=00001000");
            setexp("P2 T=00 L=00000000 S=00000000");
            setexp("P3 T=00 L=00000000 S=00000000");
            setexp("P4 T=00 L=00000000 S=00000000");
        end
        setexp("FS FAT16 BPS=00000200 SPC=04 NF=02 RE=0200 FSZ=00000020");
        setexp("F0 TEST    TXT CL=00000002 SZ=00000020");
        setexp("D0: 48 45 4C 4C 4F 5F 54 41 4E 47 5F 50 52 49 4D 45 52 5F 32 30 4B 5F 53 44 43 41 52 44 5F 58 58 58 ");
        setexp("SD OK");

        rst_n = 1'b0;
        #500;
        rst_n = 1'b1;

        // wait for all lines or timeout
        begin : wait_done
            integer guard;
            guard = 0;
            while (nlines < nexp && guard < 9000000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end

        if (nlines < nexp)
            $display("TIMEOUT: only %0d of %0d lines received", nlines, nexp);

        // debug: dump captured MBR tail + head
        $display("MBR sig0=%02x sig1=%02x", dut.mbr_sig0, dut.mbr_sig1);
        $display("MBR buf[0..7]: %02x %02x %02x %02x %02x %02x %02x %02x",
            dut.mbr_buf[0], dut.mbr_buf[1], dut.mbr_buf[2], dut.mbr_buf[3],
            dut.mbr_buf[4], dut.mbr_buf[5], dut.mbr_buf[6], dut.mbr_buf[7]);
        $display("MBR buf[60..63]: %02x %02x %02x %02x",
            dut.mbr_buf[60], dut.mbr_buf[61], dut.mbr_buf[62], dut.mbr_buf[63]);
        $display("fifo_a[0..3]=%08x %08x %08x %08x",
            dut.sd.u_sd.fifo_a[0], dut.sd.u_sd.fifo_a[1],
            dut.sd.u_sd.fifo_a[2], dut.sd.u_sd.fifo_a[3]);
        $display("sector0 bytes[0..15]=%02x %02x %02x %02x %02x %02x",
            cardmem[0], cardmem[1], cardmem[2], cardmem[3],
            cardmem[4], cardmem[5]);
        $display("fifo_a[126..127]=%08x %08x",
            dut.sd.u_sd.fifo_a[126], dut.sd.u_sd.fifo_a[127]);

        for (ei = 0; ei < nexp && ei < nlines; ei = ei + 1)
            check_line(ei);
        for (ei = nlines; ei < nexp; ei = ei + 1) begin
            fail_cnt = fail_cnt + 1;
            $display("line %0d MISSING", ei);
        end

        if (fail_cnt == 0 && nlines == nexp) $display("TB PASS");
        else $display("TB FAIL pass=%0d fail=%0d", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
