// Self-checking testbench for rmii_eth_pipe.
//
// It models the PHY side of the pipe:
//   - an MDIO slave that answers the SMI_ct master inside the DUT (BSR reports
//     link up), so the pipe reaches phy_ready the same way it will on the dock
//   - an RMII receiver that reassembles the 2-bit/cycle nibble stream produced by
//     the tx_ct instance in the DUT, verifies the CRC-32 tx_ct appends and the
//     64-octet Ethernet minimum, then scores the Ethernet/IPv4/UDP headers and the
//     payload against golden bytes
//   - an RMII transmitter that slices TB-built frames into 2-bit cycles, exactly
//     the inverse of the DUT's slicer
//
// Stimulus frames (ARP request, ICMP echo request, a UDP datagram carrying "BLK2"
// plus a known body, and two negative frames) are built here with CRC-32 and IPv4
// header checksums computed here.
//
// Run: run_tb.ps1   ->  prints "ETHPIPE SIM PASS" when every check passed.
`timescale 1ns / 1ps

module tb_rmii_eth_pipe;

    localparam [47:0] LOC_MAC  = 48'h0600AABB0CEE;
    localparam [31:0] LOC_IP   = {8'd192, 8'd168, 8'd137, 8'd16};
    localparam [15:0] UDP_PORT = 16'd11452;
    localparam integer TXRB    = 640;

    localparam [47:0] PC_MAC   = 48'hAABBCCDDEE01;
    localparam [31:0] PC_IP    = {8'd192, 8'd168, 8'd137, 8'd1};
    localparam [15:0] PC_PORT  = 16'd50001;
    localparam [15:0] BAD_PORT = 16'd60099;

    // ------------------------------------------------------------------ clocks
    reg clk50 = 0;
    reg clk1m = 0;
    reg rst_n = 0;
    always #10  clk50 = ~clk50;    // 50 MHz RMII reference clock
    always #500 clk1m = ~clk1m;    // 1 MHz MDC

    // -------------------------------------------------------------------- RMII
    reg        rx_crs = 0;
    reg [1:0]  rx_dat = 2'b11;
    wire [1:0] rmii_txd;
    wire       rmii_txen;
    wire       rmii_mdc;
    wire       mdio;
    wire       phy_rst;
    wire       phy_ready;

    // user side
    wire       rx_start, rx_valid, rx_end;
    wire [7:0] rx_data;
    wire [15:0] rx_index, rx_len;
    wire [31:0] rx_src_ip;
    wire [15:0] rx_src_port;
    reg         tx_wr = 0;
    reg  [15:0] tx_wr_addr = 0;
    reg  [7:0]  tx_wr_data = 0;
    reg         tx_req = 0;
    reg  [15:0] tx_len = 0;
    reg  [31:0] tx_dst_ip = 0;
    reg  [15:0] tx_dst_port = 0;
    wire        tx_busy, tx_done;
    wire [31:0] stat_rx_udp, stat_rx_frames, stat_ping, stat_tx_frames, stat_rx_err;

    rmii_eth_pipe #(
        .LOCAL_MAC(LOC_MAC), .LOCAL_IP(LOC_IP), .UDP_PORT(UDP_PORT),
        .TX_RAM_BYTES(TXRB)
    ) dut (
        .clk50m(clk50), .clk1m(clk1m), .rst_n(rst_n),
        .rmii_rx_crs_dv(rx_crs), .rmii_rxd(rx_dat),
        .rmii_txd(rmii_txd), .rmii_txen(rmii_txen),
        .rmii_mdc(rmii_mdc), .rmii_mdio(mdio),
        .phy_rst(phy_rst), .phy_ready(phy_ready),
        .rx_start(rx_start), .rx_valid(rx_valid), .rx_data(rx_data),
        .rx_index(rx_index), .rx_len(rx_len), .rx_end(rx_end),
        .rx_src_ip(rx_src_ip), .rx_src_port(rx_src_port),
        .tx_wr(tx_wr), .tx_wr_addr(tx_wr_addr), .tx_wr_data(tx_wr_data),
        .tx_req(tx_req), .tx_len(tx_len), .tx_dst_ip(tx_dst_ip),
        .tx_dst_port(tx_dst_port), .tx_busy(tx_busy), .tx_done(tx_done),
        .stat_rx_udp(stat_rx_udp), .stat_rx_frames(stat_rx_frames),
        .stat_ping(stat_ping), .stat_tx_frames(stat_tx_frames),
        .stat_rx_err(stat_rx_err)
    );

    // MDIO idle level, so the wire resolves to 1 when nothing drives it
    pullup (mdio);

    integer errors = 0;

    // ----------------------------------------------------------- MDIO slave --
    // SMI_ct puts one 32-bit MDIO frame on the wire, one bit-time per MDC (== clk1m)
    // cycle, MSB first.  Numbering the bit-times in transmission order:
    //   0,1      = ST (0 then 1)   2,3 = OP (2'b10 = read, 2'b01 = write)
    //   4 .. 8   = PHY address     9 .. 13 = register address, MSB first
    //   14, 15   = turnaround      16 .. 31 = data, MSB first
    // The master drives 0..13 and releases 14..31 (the pull-up holds the line high
    // for a read).  It samples the slave's acknowledge during bit-time 15 and the
    // read data during 16..31.  The posedge that *samples* bit-time b is the one
    // where mdio_pos == b, and a non-blocking assignment made there lands on the
    // wire for bit-time b+1.
    reg        mdio_drive = 0;
    reg        mdio_bit   = 0;
    reg [15:0] mdio_shift = 0;
    reg        md_vec [0:31];
    reg [5:0]  mdio_pos   = 0;
    reg        mdio_in_tx = 0;
    reg        md_read    = 0;
    reg [4:0]  md_ra      = 0;
    integer    md_frames  = 0;
    integer    md_bad_st  = 0;

    assign mdio = mdio_drive ? mdio_bit : 1'bz;

    always @(posedge clk1m) begin
        if (!mdio_in_tx) begin
            if (mdio === 1'b0) begin                 // leading 0 of ST = bit-time 0
                mdio_in_tx <= 1'b1;
                mdio_pos   <= 6'd1;
                md_vec[0]   = 1'b0;                  // sampled by this very edge
            end
        end else begin
            md_vec[mdio_pos] = (mdio === 1'b1);
            if (mdio_pos == 6'd13) begin             // header complete
                md_read <= (md_vec[2] && !md_vec[3]);
                md_ra   <= {md_vec[9], md_vec[10], md_vec[11], md_vec[12], md_vec[13]};
                if (md_vec[0] !== 1'b0 || md_vec[1] !== 1'b1) md_bad_st = md_bad_st + 1;
            end else if (mdio_pos == 6'd14) begin     // answer the turnaround at 15
                mdio_drive <= md_read;
                mdio_bit   <= 1'b0;
                mdio_shift <= mdio_read(md_ra);
            end else if (mdio_pos >= 6'd15 && mdio_pos <= 6'd30) begin
                if (mdio_drive) begin
                    mdio_bit   <= mdio_shift[15];
                    mdio_shift <= {mdio_shift[14:0], 1'b1};
                end
            end else if (mdio_pos == 6'd31) begin
                mdio_drive <= 1'b0;                   // release the line, frame over
                mdio_in_tx <= 1'b0;
                md_frames  = md_frames + 1;
            end
            if (mdio_pos != 6'd31) mdio_pos <= mdio_pos + 6'd1;
        end
    end

    function automatic [15:0] mdio_read;
        input [4:0] ra;
        begin
            case (ra)
                5'd1:    mdio_read = 16'h0004;   // BSR: link up, autoneg complete
                5'd16:   mdio_read = 16'h0FFE;
                5'd31:   mdio_read = 16'h0007;
                default: mdio_read = 16'd0;
            endcase
        end
    endfunction

    // ----------------------------------------------------- capture of TX -----
    // RMII carries two bits per cycle, four cycles per octet: cycle 0 of an octet
    // holds its bits [1:0] and cycle 3 holds bits [7:6], exactly what tx_ct emits.
    // The preamble/SFD (7x 0x55 + 0xD5) is consumed but not recorded, so fstart[]
    // indexes the destination MAC address and flen[] is the Ethernet frame length.
    reg [7:0] capall [0:16383];
    integer   capw = 0;
    integer   fstart [0:63];
    integer   flen   [0:63];
    integer   nframes = 0;
    integer   frame_base = 0;
    integer   frame_bytes = 0;
    integer   pre_cnt = 0;
    reg [3:0] cnn = 0;
    reg [1:0] cnib0 = 0, cnib1 = 0, cnib2 = 0, cnib3 = 0;
    reg       txen_d = 0;

    always @(posedge clk50) begin
        txen_d <= rmii_txen;
        if (rmii_txen) begin
            case (cnn)
                4'd0: cnib0 = rmii_txd;
                4'd1: cnib1 = rmii_txd;
                4'd2: cnib2 = rmii_txd;
                default: begin
                    cnib3 = rmii_txd;
                    capall[capw] = {cnib3, cnib2, cnib1, cnib0};
                    capw = capw + 1;
                    if (pre_cnt < 8) begin
                        if (pre_cnt == 7) frame_base = capw;   // body follows the SFD
                        pre_cnt = pre_cnt + 1;
                    end else begin
                        frame_bytes = frame_bytes + 1;
                    end
                end
            endcase
            cnn = (cnn == 4'd3) ? 4'd0 : cnn + 4'd1;
        end else begin
            cnn = 4'd0;
            pre_cnt = 0;
            if (txen_d) begin                         // frame just finished
                fstart[nframes] = frame_base;
                flen[nframes]   = frame_bytes;
                nframes         = nframes + 1;
                frame_bytes     = 0;
            end
        end
    end

    integer tx_done_pulses = 0;
    always @(posedge clk50)
        if (tx_done) tx_done_pulses = tx_done_pulses + 1;

    // ----------------------------------------------------- received payload --
    reg [7:0]  rxgot [0:1023];
    integer    rxgot_n = 0;
    integer    rx_starts = 0;
    integer    rx_ends = 0;
    integer    rx_start_at = -1;
    reg [15:0] rx_end_len = 0;
    reg [31:0] rx_end_ip = 0;
    reg [15:0] rx_end_port = 0;

    always @(posedge clk50) begin
        if (rx_start) begin
            rx_starts   = rx_starts + 1;
            rx_start_at = rxgot_n;      // 0 when it shares the first byte
        end
        if (rx_valid) begin
            if (rxgot_n < 1024) rxgot[rxgot_n] = rx_data;
            if (rx_index !== rxgot_n[15:0]) begin
                $display("FAIL: rx_index %0d while %0d payload octets already seen",
                         rx_index, rxgot_n);
                errors = errors + 1;
            end
            if (rx_ends > 0) begin
                $display("FAIL: rx_valid after rx_end of the previous datagram");
                errors = errors + 1;
            end
            rxgot_n = rxgot_n + 1;
        end
        if (rx_end) begin
            rx_ends     = rx_ends + 1;
            rx_end_len  = rx_len;
            rx_end_ip   = rx_src_ip;
            rx_end_port = rx_src_port;
        end
    end

    task rx_reset;
        begin
            rxgot_n = 0; rx_starts = 0; rx_ends = 0; rx_start_at = -1;
            rx_end_len = 0; rx_end_ip = 0; rx_end_port = 0;
        end
    endtask

    // -------------------------------------------------------------- buffers --
    reg [7:0] obuf [0:1023];        // stimulus frame under construction
    integer   olen;
    reg [7:0] pbuf [0:511];         // payload of stimulus frames
    reg [7:0] golden [0:511];       // golden bytes scored by the scoreboard
    integer   glen;
    reg [7:0] txbody [0:1023];      // body written into the pipe TX RAM
    integer   tbody_n;

    integer expect_pay = 0;         // payload octets the scoreboard wants
    reg [15:0] expect_id = 0;
    reg [15:0] expect_seq = 0;
    integer exp_src = 0;            // offset into golden[] of expected payload

    // ------------------------------------------------------------- CRC-32 ----
    // Standard Ethernet CRC-32 (reflected, init/complement 0xFFFFFFFF), FCS octets
    // on the wire low byte first.
    function automatic [31:0] crc32_cap;
        input integer len;
        input integer base;
        integer i, k;
        reg [31:0] r;
        begin
            r = 32'hFFFFFFFF;
            for (i = 0; i < len; i = i + 1) begin
                r = r ^ {24'h000000, capall[base + i]};
                for (k = 0; k < 8; k = k + 1)
                    r = r[0] ? ({1'b0, r[31:1]} ^ 32'hEDB88320) : {1'b0, r[31:1]};
            end
            crc32_cap = ~r;
        end
    endfunction

    function automatic [31:0] crc32_obuf;
        input integer len;
        integer i, k;
        reg [31:0] r;
        begin
            r = 32'hFFFFFFFF;
            for (i = 0; i < len; i = i + 1) begin
                r = r ^ {24'h000000, obuf[i]};
                for (k = 0; k < 8; k = k + 1)
                    r = r[0] ? ({1'b0, r[31:1]} ^ 32'hEDB88320) : {1'b0, r[31:1]};
            end
            crc32_obuf = ~r;
        end
    endfunction

    function automatic [7:0] obuf_fcs;
        input integer len;
        input integer which;
        reg [31:0] c;
        begin
            c = crc32_obuf(len);
            case (which)
                0:       obuf_fcs = c[7:0];
                1:       obuf_fcs = c[15:8];
                2:       obuf_fcs = c[23:16];
                default: obuf_fcs = c[31:24];
            endcase
        end
    endfunction

    // ------------------------------------------------------------ checksums --
    function automatic [15:0] sum_cap;
        input integer len;
        input integer start;
        integer i;
        reg [31:0] s;
        begin
            s = 32'd0;
            for (i = 0; i + 1 < len; i = i + 2)
                s = s + {capall[start + i], capall[start + i + 1]};
            if ((len % 2) == 1) s = s + {capall[start + len - 1], 8'h00};
            s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
            s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
            sum_cap = s[15:0];
        end
    endfunction

    // ------------------------------------------------------ stimulus builders
    task put_ipv4;
        input [7:0]  proto;
        input [31:0] src;
        input [31:0] dst;
        input integer ip_len;
        integer i;
        reg [15:0] cs;
        begin
            obuf[14] = 8'h45; obuf[15] = 8'h00;
            obuf[16] = ip_len[15:8]; obuf[17] = ip_len[7:0];
            obuf[18] = 8'h00; obuf[19] = 8'h01;
            obuf[20] = 8'h40; obuf[21] = 8'h00;
            obuf[22] = 8'h40; obuf[23] = proto;
            obuf[24] = 8'h00; obuf[25] = 8'h00;
            for (i = 0; i < 4; i = i + 1) begin
                obuf[26 + i] = src[(3 - i) * 8 +: 8];
                obuf[30 + i] = dst[(3 - i) * 8 +: 8];
            end
            cs = ~sum_obuf(20, 14);
            obuf[24] = cs[15:8];
            obuf[25] = cs[7:0];
        end
    endtask

    function automatic [15:0] sum_obuf;
        input integer len;
        input integer start;
        integer i;
        reg [31:0] s;
        begin
            s = 32'd0;
            for (i = 0; i + 1 < len; i = i + 2)
                s = s + {obuf[start + i], obuf[start + i + 1]};
            if ((len % 2) == 1) s = s + {obuf[start + len - 1], 8'h00};
            s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
            s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
            sum_obuf = s[15:0];
        end
    endfunction

    task build_arp_request;
        input [47:0] sha;
        input [31:0] spa;
        input [31:0] tpa;
        integer i;
        begin
            obuf[0] = 8'hFF; obuf[1] = 8'hFF; obuf[2] = 8'hFF;
            obuf[3] = 8'hFF; obuf[4] = 8'hFF; obuf[5] = 8'hFF;
            for (i = 0; i < 6; i = i + 1) obuf[6 + i] = sha[(5 - i) * 8 +: 8];
            obuf[12] = 8'h08; obuf[13] = 8'h06;
            obuf[14] = 8'h00; obuf[15] = 8'h01;
            obuf[16] = 8'h08; obuf[17] = 8'h00;
            obuf[18] = 8'h06; obuf[19] = 8'h04;
            obuf[20] = 8'h00; obuf[21] = 8'h01;
            for (i = 0; i < 6; i = i + 1) obuf[22 + i] = sha[(5 - i) * 8 +: 8];
            for (i = 0; i < 4; i = i + 1) obuf[28 + i] = spa[(3 - i) * 8 +: 8];
            for (i = 0; i < 6; i = i + 1) obuf[32 + i] = 8'h00;
            for (i = 0; i < 4; i = i + 1) obuf[38 + i] = tpa[(3 - i) * 8 +: 8];
            olen = 42;
        end
    endtask

    task build_icmp_echo;
        input [15:0] id;
        input [15:0] seq;
        input integer body;
        integer i;
        reg [15:0] cs;
        begin
            for (i = 0; i < 6; i = i + 1) obuf[i] = LOC_MAC[(5 - i) * 8 +: 8];
            for (i = 0; i < 6; i = i + 1) obuf[6 + i] = PC_MAC[(5 - i) * 8 +: 8];
            obuf[12] = 8'h08; obuf[13] = 8'h00;
            put_ipv4(8'h01, PC_IP, LOC_IP, 28 + body);
            obuf[34] = 8'h08; obuf[35] = 8'h00;         // echo request
            obuf[36] = 8'h00; obuf[37] = 8'h00;         // checksum filled below
            obuf[38] = id[15:8]; obuf[39] = id[7:0];
            obuf[40] = seq[15:8]; obuf[41] = seq[7:0];
            for (i = 0; i < body; i = i + 1) obuf[42 + i] = pbuf[i];
            cs = ~sum_obuf(8 + body, 34);
            obuf[36] = cs[15:8];
            obuf[37] = cs[7:0];
            olen = 42 + body;
        end
    endtask

    task build_udp;
        input [15:0] sport;
        input [15:0] dport;
        input [31:0] dst;
        input integer body;
        integer i;
        begin
            for (i = 0; i < 6; i = i + 1) obuf[i] = LOC_MAC[(5 - i) * 8 +: 8];
            for (i = 0; i < 6; i = i + 1) obuf[6 + i] = PC_MAC[(5 - i) * 8 +: 8];
            obuf[12] = 8'h08; obuf[13] = 8'h00;
            put_ipv4(8'h11, PC_IP, dst, 28 + body);
            obuf[34] = sport[15:8]; obuf[35] = sport[7:0];
            obuf[36] = dport[15:8]; obuf[37] = dport[7:0];
            obuf[38] = 8'h00; obuf[39] = (8 + body) & 8'hFF;
            obuf[40] = 8'h00; obuf[41] = 8'h00;
            for (i = 0; i < body; i = i + 1) obuf[42 + i] = pbuf[i];
            olen = 42 + body;
        end
    endtask

    // ---------------------------------------------------------- RX driving ---
    // The slicer in the DUT samples rmii_rxd with the same cycle in which it sees
    // crs_dv, and crs_dv is high for the four cycles of every octet.  Delaying crs
    // by one cycle (a delayed assignment) aligns it with the data nibble, which is
    // how the PHY presents RXDV.
    task drive_octet;
        input [7:0] b;
        begin
            @(posedge clk50); rx_crs <= 1'b1; rx_dat <= b[1:0];
            @(posedge clk50);                    rx_dat <= b[3:2];
            @(posedge clk50);                    rx_dat <= b[5:4];
            @(posedge clk50);                    rx_dat <= b[7:6];
        end
    endtask

    task send_frame;
        input integer len;
        integer i;
        begin
            rx_crs <= 1'b0; rx_dat <= 2'b11;
            @(posedge clk50); @(posedge clk50);
            for (i = 0; i < 7; i = i + 1) drive_octet(8'h55);
            drive_octet(8'hD5);
            for (i = 0; i < len; i = i + 1) drive_octet(obuf[i]);
            for (i = 0; i < 4; i = i + 1) drive_octet(obuf_fcs(len, i));
            @(posedge clk50); rx_crs <= 1'b0; rx_dat <= 2'b11;
            repeat (8) @(posedge clk50);
        end
    endtask

    // ------------------------------------------------------------ scoreboard --
    integer ip_id_prev = 0;
    integer ip_id_first = 1;

    task score_frame;
        input integer fi;
        integer   base, len, i, crcv, pl, pay, msg_len;
        reg [47:0] dm, sm;
        reg [15:0] et, tlen, fl, id, dport, sport;
        reg [15:0] ipsum, got_c;
        begin
            base = fstart[fi];
            len  = flen[fi];
            if (len < 64) begin
                $display("FAIL: frame %0d is %0d octets, below the 64-octet minimum",
                         fi, len);
                errors = errors + 1;
            end
            if (len < 4) begin
                $display("FAIL: frame %0d too short to carry an FCS", fi);
                errors = errors + 1;
                dm = 48'd0; sm = 48'd0; et = 16'h0800;
            end else begin
                crcv = crc32_cap(len - 4, base);
                if (capall[base+len-4] !== crcv[7:0]   ||
                    capall[base+len-3] !== crcv[15:8]  ||
                    capall[base+len-2] !== crcv[23:16] ||
                    capall[base+len-1] !== crcv[31:24]) begin
                    $display("FAIL: frame %0d FCS mismatch, expected %h08 got %02h %02h %02h %02h",
                             fi, crcv, capall[base+len-4], capall[base+len-3],
                             capall[base+len-2], capall[base+len-1]);
                    errors = errors + 1;
                end
                dm = {capall[base+0], capall[base+1], capall[base+2],
                      capall[base+3], capall[base+4], capall[base+5]};
                sm = {capall[base+6], capall[base+7], capall[base+8],
                      capall[base+9], capall[base+10], capall[base+11]};
                et = {capall[base+12], capall[base+13]};
            end
            if (sm !== LOC_MAC) begin
                $display("FAIL: frame %0d source MAC %h, expected %h", fi, sm, LOC_MAC);
                errors = errors + 1;
            end

            if (et === 16'h0806) begin
                if (dm !== PC_MAC) begin
                    $display("FAIL: ARP reply dest MAC %h, expected %h", dm, PC_MAC);
                    errors = errors + 1;
                end
                if (flen[fi] < 64) begin
                    $display("FAIL: ARP reply is %0d octets, below the 64-octet Ethernet minimum",
                             flen[fi]);
                    errors = errors + 1;
                end
                // tx_ct pads the frame body to 64 octets and then appends its 4-octet
                // CRC, so a short reply arrives as 68 octets.  Anything longer means the
                // pipe emitted payload it should not have.
                if (flen[fi] > 68) begin
                    $display("FAIL: ARP reply is %0d octets, expected the padded minimum",
                             flen[fi]);
                    errors = errors + 1;
                end
                if (capall[base+21] !== 8'h02) begin
                    $display("FAIL: ARP opcode %02d, expected 2 (reply)", capall[base+21]);
                    errors = errors + 1;
                end
                for (i = 0; i < 6; i = i + 1)
                    if (capall[base+22+i] !== LOC_MAC[(5-i)*8 +: 8]) begin
                        $display("FAIL: ARP sender MAC byte %0d = %02h", i, capall[base+22+i]);
                        errors = errors + 1;
                    end
                for (i = 0; i < 4; i = i + 1)
                    if (capall[base+28+i] !== LOC_IP[(3-i)*8 +: 8]) begin
                        $display("FAIL: ARP sender IP byte %0d = %02h", i, capall[base+28+i]);
                        errors = errors + 1;
                    end
                for (i = 0; i < 6; i = i + 1)
                    if (capall[base+32+i] !== PC_MAC[(5-i)*8 +: 8]) begin
                        $display("FAIL: ARP target MAC byte %0d = %02h", i, capall[base+32+i]);
                        errors = errors + 1;
                    end
                for (i = 0; i < 4; i = i + 1)
                    if (capall[base+38+i] !== PC_IP[(3-i)*8 +: 8]) begin
                        $display("FAIL: ARP target IP byte %0d = %02h", i, capall[base+38+i]);
                        errors = errors + 1;
                    end
            end else if (et === 16'h0800) begin
                id    = {capall[base+18], capall[base+19]};
                fl    = {capall[base+20], capall[base+21]};
                tlen  = {capall[base+16], capall[base+17]};
                ipsum = sum_cap(20, base + 14);
                if (ip_id_first) begin
                    ip_id_first = 0;
                    ip_id_prev  = id;
                end else if (id > ip_id_prev) begin
                    ip_id_prev = id;
                end else begin
                    $display("FAIL: frame %0d IP id %04d does not increase past %04d",
                             fi, id, ip_id_prev);
                    errors = errors + 1;
                end
                if (fl !== 16'h4000) begin
                    $display("FAIL: IP flags/fragment field %h, expected 4000 (DF only)", fl);
                    errors = errors + 1;
                end
                if (capall[base+22] !== 8'h40) begin
                    $display("FAIL: IP TTL %0d, expected 64", capall[base+22]);
                    errors = errors + 1;
                end
                if (ipsum !== 16'hFFFF) begin
                    $display("FAIL: frame %0d IP header checksum folds to %h, expected ffff",
                             fi, ipsum);
                    errors = errors + 1;
                end
                for (i = 0; i < 4; i = i + 1)
                    if (capall[base+26+i] !== LOC_IP[(3-i)*8 +: 8]) begin
                        $display("FAIL: IP source byte %0d = %02h", i, capall[base+26+i]);
                        errors = errors + 1;
                    end
                if (dm !== PC_MAC) begin
                    $display("FAIL: IPv4 reply dest MAC %h, expected %h", dm, PC_MAC);
                    errors = errors + 1;
                end
                if (capall[base+23] === 8'h11) begin
                    for (i = 0; i < 4; i = i + 1)
                        if (capall[base+30+i] !== PC_IP[(3-i)*8 +: 8]) begin
                            $display("FAIL: UDP reply dest IP byte %0d = %02h", i,
                                     capall[base+30+i]);
                            errors = errors + 1;
                        end
                    sport = {capall[base+34], capall[base+35]};
                    dport = {capall[base+36], capall[base+37]};
                    if (sport !== UDP_PORT) begin
                        $display("FAIL: UDP reply source port %0d, expected %0d", sport, UDP_PORT);
                        errors = errors + 1;
                    end
                    if (dport !== PC_PORT) begin
                        $display("FAIL: UDP reply dest port %0d, expected %0d", dport, PC_PORT);
                        errors = errors + 1;
                    end
                    if (tlen !== (28 + expect_pay)) begin
                        $display("FAIL: UDP reply IP length %0d, expected %0d",
                                 tlen, 28 + expect_pay);
                        errors = errors + 1;
                    end
                    if ({capall[base+38], capall[base+39]} !== (8 + expect_pay)) begin
                        $display("FAIL: UDP length field %0d, expected %0d",
                                 {capall[base+38], capall[base+39]}, 8 + expect_pay);
                        errors = errors + 1;
                    end
                    if ({capall[base+40], capall[base+41]} !== 16'd0) begin
                        $display("FAIL: UDP checksum field is not 0");
                        errors = errors + 1;
                    end
                    pl  = tlen - 28;   // IP header (20) + UDP header (8)
                    pay = 42 + pl;
                    if (pl !== expect_pay) begin
                        $display("FAIL: UDP payload %0d octets, expected %0d", pl, expect_pay);
                        errors = errors + 1;
                    end
                    if (pay > len - 4) begin
                        $display("FAIL: UDP payload runs past the FCS");
                        errors = errors + 1;
                        pay = len - 4;
                    end
                    for (i = 42; i < pay; i = i + 1)
                        if (capall[base+i] !== golden[exp_src + (i - 42)]) begin
                            $display("FAIL: UDP payload octet %0d = %02h, expected %02h",
                                     i - 42, capall[base+i], golden[exp_src + (i - 42)]);
                            errors = errors + 1;
                        end
                    for (i = pay; i < len - 4; i = i + 1)
                        if (capall[base+i] !== 8'h00) begin
                            $display("FAIL: padding octet %0d = %02h, expected 00",
                                     i, capall[base+i]);
                            errors = errors + 1;
                        end
                end else begin
                    if (capall[base+23] !== 8'h01) begin
                        $display("FAIL: IPv4 reply protocol %02d, expected ICMP", capall[base+23]);
                        errors = errors + 1;
                    end
                    if (tlen !== (28 + expect_pay)) begin
                        $display("FAIL: ICMP reply IP length %0d, expected %0d",
                                 tlen, 28 + expect_pay);
                        errors = errors + 1;
                    end
                    if (capall[base+34] !== 8'h00 || capall[base+35] !== 8'h00) begin
                        $display("FAIL: ICMP type/code %02h %02h, expected 00 00",
                                 capall[base+34], capall[base+35]);
                        errors = errors + 1;
                    end
                    if ({capall[base+38], capall[base+39]} !== expect_id) begin
                        $display("FAIL: ICMP id %h, expected %h",
                                 {capall[base+38], capall[base+39]}, expect_id);
                        errors = errors + 1;
                    end
                    if ({capall[base+40], capall[base+41]} !== expect_seq) begin
                        $display("FAIL: ICMP seq %h, expected %h",
                                 {capall[base+40], capall[base+41]}, expect_seq);
                        errors = errors + 1;
                    end
                    msg_len = 8 + expect_pay;
                    got_c   = {capall[base+36], capall[base+37]};
                    ipsum   = sum_cap(msg_len, base + 34);
                    if (ipsum !== 16'hFFFF) begin
                        $display("FAIL: ICMP echo reply checksum %h does not fold (%h)",
                                 got_c, ipsum);
                        errors = errors + 1;
                    end
                    for (i = 0; i < expect_pay; i = i + 1)
                        if (capall[base+42+i] !== golden[exp_src + i]) begin
                            $display("FAIL: ICMP echo octet %0d = %02h, expected %02h",
                                     i, capall[base+42+i], golden[exp_src + i]);
                            errors = errors + 1;
                        end
                    for (i = 42 + expect_pay; i < len - 4; i = i + 1)
                        if (capall[base+i] !== 8'h00) begin
                            $display("FAIL: ICMP padding octet %0d = %02h, expected 00",
                                     i, capall[base+i]);
                            errors = errors + 1;
                        end
                end
            end else begin
                $display("FAIL: frame %0d has unexpected ethertype %h", fi, et);
                errors = errors + 1;
            end
        end
    endtask

    // --------------------------------------------------------- TX RAM model --
    task ram_fill;
        integer i;
        begin
            // Writes happen while tx_busy is low.  The final tx_wr deliberately
            // shares the tx_req cycle, to prove the pipe does not read that octet
            // before it has landed in the RAM.
            for (i = 0; i < tbody_n; i = i + 1) begin
                @(posedge clk50);
                tx_wr      <= 1'b1;
                tx_wr_addr <= i[15:0];
                tx_wr_data <= txbody[i];
            end
            tx_len      <= tbody_n[15:0];
            tx_dst_ip   <= PC_IP;
            tx_dst_port <= PC_PORT;
            tx_req      <= 1'b1;                 // same cycle as the last tx_wr
            @(posedge clk50);
            // Everything drops with tx_req: the pipe must have latched the request on
            // that one cycle, so a later change of these inputs cannot influence it.
            tx_wr       <= 1'b0;
            tx_req      <= 1'b0;
            tx_len      <= 16'd0;
            tx_dst_ip   <= 32'd0;
            tx_dst_port <= 16'd0;
        end
    endtask

    // ---------------------------------------------------------- wait helpers --
    task wait_tx_frame;
        input integer n_before;
        integer k;
        begin
            k = 0;
            while (nframes <= n_before && k < 400000) begin
                @(posedge clk50);
                k = k + 1;
            end
            if (nframes <= n_before) begin
                $display("FAIL: no transmit frame captured after %0d clk50 cycles", k);
                errors = errors + 1;
            end
            repeat (12) @(posedge clk50);
        end
    endtask

    task wait_rx_end;
        integer k;
        begin
            k = 0;
            while (rx_ends == 0 && k < 200000) begin
                @(posedge clk50);
                k = k + 1;
            end
            if (rx_ends == 0) begin
                $display("FAIL: rx_end never pulsed");
                errors = errors + 1;
            end
            repeat (12) @(posedge clk50);
        end
    endtask

    task wait_frames;
        input integer want;
        integer k;
        begin
            k = 0;
            while (nframes < want && k < 400000) begin
                @(posedge clk50);
                k = k + 1;
            end
            repeat (12) @(posedge clk50);
        end
    endtask

    // ------------------------------------------------------------------ main --
    integer i;
    integer n_before;
    integer pulses_before;

    initial begin : main
        for (i = 0; i < 1024; i = i + 1) obuf[i] = 8'h00;
        for (i = 0; i < 512; i = i + 1) golden[i] = 8'h00;

        // ---- bring-up: PHY reset released, SMI init, link established ----
        // rst_n is released one clk1m cycle after a posedge that saw it low, so the
        // DUT's clk1m state machine is guaranteed to be initialised before it starts.
        rst_n = 0;
        repeat (10) @(posedge clk50);
        @(posedge clk1m);
        #1;
        rst_n = 1;

        begin : wait_link
            integer k;
            k = 0;
            while (phy_ready !== 1'b1 && k < 20000) begin
                @(posedge clk1m);
                k = k + 1;
            end
            if (phy_ready !== 1'b1) begin
                $display("FAIL: phy_ready never asserted - MDIO model or SMI init broken");
                $display("      MDIO frames decoded: %0d, bad ST fields: %0d",
                         md_frames, md_bad_st);
                errors = errors + 1;
            end else begin
                $display("note: link established after %0d clk1m cycles, %0d MDIO frames decoded (%0d bad ST)",
                         k, md_frames, md_bad_st);
            end
        end
        repeat (40) @(posedge clk50);

        // ================= 1. ARP resolution by a cold peer ==================
        $display("step 1: ARP request from 192.168.137.1");
        build_arp_request(PC_MAC, PC_IP, LOC_IP);
        send_frame(olen);
        n_before = nframes;
        wait_tx_frame(n_before);
        expect_pay = 0;
        score_frame(n_before);

        // ================= 2. ICMP echo request ==============================
        $display("step 2: ICMP echo request, 16 body octets");
        for (i = 0; i < 16; i = i + 1) begin
            pbuf[i]   = 8'h41 + i[7:0];
            golden[i] = 8'h41 + i[7:0];
        end
        expect_pay = 16; exp_src = 0;
        expect_id  = 16'h1234; expect_seq = 16'h5678;
        build_icmp_echo(16'h1234, 16'h5678, 16);
        send_frame(olen);
        n_before = nframes;
        wait_tx_frame(n_before);
        score_frame(n_before);
        if (stat_ping !== 32'd1) begin
            $display("FAIL: stat_ping = %0d, expected 1", stat_ping);
            errors = errors + 1;
        end

        // ================= 3. UDP datagram in, streamed out ==================
        $display("step 3: UDP datagram 'BLK2' + body in");
        pbuf[0] = "B"; pbuf[1] = "L"; pbuf[2] = "K"; pbuf[3] = "2";
        for (i = 4; i < 16; i = i + 1) pbuf[i] = 8'hA0 + i[7:0] * 8'd3;
        rx_reset();
        build_udp(PC_PORT, UDP_PORT, LOC_IP, 16);
        send_frame(olen);
        wait_rx_end();
        if (rxgot_n !== 16) begin
            $display("FAIL: streamed %0d payload octets, expected 16", rxgot_n);
            errors = errors + 1;
        end
        if (rx_starts !== 1) begin
            $display("FAIL: rx_start pulsed %0d times, expected 1", rx_starts);
            errors = errors + 1;
        end
        if (rx_start_at !== 0) begin
            $display("FAIL: rx_start arrived with payload octet index %0d", rx_start_at);
            errors = errors + 1;
        end
        if (rx_ends !== 1) begin
            $display("FAIL: rx_end pulsed %0d times, expected 1", rx_ends);
            errors = errors + 1;
        end
        if (rx_end_len !== 16'd16) begin
            $display("FAIL: rx_len = %0d, expected 16", rx_end_len);
            errors = errors + 1;
        end
        if (rx_end_ip !== PC_IP) begin
            $display("FAIL: rx_src_ip = %h, expected %h", rx_end_ip, PC_IP);
            errors = errors + 1;
        end
        if (rx_end_port !== PC_PORT) begin
            $display("FAIL: rx_src_port = %0d, expected %0d", rx_end_port, PC_PORT);
            errors = errors + 1;
        end
        for (i = 0; i < 16; i = i + 1)
            if (rxgot[i] !== pbuf[i]) begin
                $display("FAIL: rx octet %0d = %02h, expected %02h", i, rxgot[i], pbuf[i]);
                errors = errors + 1;
            end

        // the pipe must not answer a datagram by itself: that is the harness's job
        repeat (200) @(posedge clk50);
        if (nframes !== 2) begin
            $display("FAIL: the pipe transmitted %0d frames after a UDP datagram, expected none",
                     nframes - 2);
            errors = errors + 1;
        end
        if (stat_tx_frames !== 32'd2) begin
            $display("FAIL: stat_tx_frames = %0d after ARP + ICMP, expected 2", stat_tx_frames);
            errors = errors + 1;
        end

        // ================= 4. peer filled TX RAM back to the peer ============
        $display("step 4: host TX RAM, 40 octets back to the peer port");
        while (tx_busy) @(posedge clk50);
        repeat (60) @(posedge clk50);
        tbody_n = 40;
        for (i = 0; i < tbody_n; i = i + 1) begin
            txbody[i] = 8'h10 + i[7:0] * 8'd7;
            golden[i] = txbody[i];
        end
        exp_src = 0; expect_pay = tbody_n;
        n_before = nframes;
        pulses_before = tx_done_pulses;
        ram_fill();
        wait_tx_frame(n_before);
        score_frame(n_before);
        if (tx_done_pulses !== pulses_before + 1) begin
            $display("FAIL: tx_done pulsed %0d times for one request",
                     tx_done_pulses - pulses_before);
            errors = errors + 1;
        end

        // ================= 5. larger datagram, exercises tx_av flow ==========
        $display("step 5: host TX RAM, 300 octets");
        while (tx_busy) @(posedge clk50);
        repeat (60) @(posedge clk50);
        tbody_n = 300;
        for (i = 0; i < tbody_n; i = i + 1) begin
            txbody[i] = (i[7:0] * 8'd5) ^ 8'hC3;
            golden[i] = txbody[i];
        end
        exp_src = 0; expect_pay = tbody_n;
        n_before = nframes;
        pulses_before = tx_done_pulses;
        ram_fill();
        wait_tx_frame(n_before);
        score_frame(n_before);
        if (tx_done_pulses !== pulses_before + 1) begin
            $display("FAIL: tx_done pulsed %0d times for one 300-octet request",
                     tx_done_pulses - pulses_before);
            errors = errors + 1;
        end

        // ================= 6. ICMP echo with an ODD body length ================
        // The odd final octet must be zero padded inside the checksum, not paired with
        // the first octet of whatever follows it.
        $display("step 6: ICMP echo request, 15 body octets (odd length)");
        for (i = 0; i < 15; i = i + 1) begin
            pbuf[i]   = 8'hC0 + i[7:0];
            golden[i] = pbuf[i];
        end
        expect_pay = 15; exp_src = 0;
        expect_id  = 16'hAAAA; expect_seq = 16'h0007;
        build_icmp_echo(16'hAAAA, 16'h0007, 15);
        send_frame(olen);
        n_before = nframes;
        wait_tx_frame(n_before);
        score_frame(n_before);

        // ================= 7. ICMP echo longer than the 64-octet echo budget ====
        // The pipe echoes at most 64 payload octets, whatever the request carried.
        $display("step 7: ICMP echo request, 100 body octets, only 64 echoed");
        for (i = 0; i < 100; i = i + 1) begin
            pbuf[i]   = (i[7:0] * 8'd3) ^ 8'h5F;
            golden[i] = pbuf[i];
        end
        expect_pay = 64; exp_src = 0;
        expect_id  = 16'h00FF; expect_seq = 16'hFF00;
        build_icmp_echo(16'h00FF, 16'hFF00, 100);
        send_frame(olen);
        n_before = nframes;
        wait_tx_frame(n_before);
        score_frame(n_before);
        if (stat_ping !== 32'd3) begin
            $display("FAIL: stat_ping = %0d after three echo requests, expected 3", stat_ping);
            errors = errors + 1;
        end

        // ================= 8. negative: wrong UDP port =======================
        $display("step 8: UDP datagram on the wrong port must raise stat_rx_err");
        rx_reset();
        begin : wrong_port
            integer e0, s0;
            e0 = stat_rx_err; s0 = stat_rx_udp;
            pbuf[0] = "B"; pbuf[1] = "L"; pbuf[2] = "K"; pbuf[3] = "2";
            for (i = 4; i < 16; i = i + 1) pbuf[i] = 8'hA0 + i[7:0] * 8'd3;
            build_udp(PC_PORT, BAD_PORT, LOC_IP, 16);
            send_frame(olen);
            repeat (400) @(posedge clk50);
            if (stat_rx_err <= e0) begin
                $display("FAIL: wrong-port datagram did not raise stat_rx_err");
                errors = errors + 1;
            end
            if (rxgot_n !== 0 || rx_starts !== 0 || rx_ends !== 0) begin
                $display("FAIL: wrong-port datagram produced an rx stream");
                errors = errors + 1;
            end
            if (stat_rx_udp !== s0) begin
                $display("FAIL: wrong-port datagram counted as received");
                errors = errors + 1;
            end
        end

        // ================= 9. negative: corrupted IP header checksum ========
        $display("step 9: datagram with a bad IP header checksum must be rejected");
        rx_reset();
        begin : bad_ip_csum
            integer e0, s0;
            e0 = stat_rx_err; s0 = stat_rx_udp;
            build_udp(PC_PORT, UDP_PORT, LOC_IP, 16);
            obuf[24] = obuf[24] ^ 8'hFF;          // break the header checksum
            send_frame(olen);
            repeat (400) @(posedge clk50);
            if (stat_rx_err <= e0) begin
                $display("FAIL: bad IP header checksum did not raise stat_rx_err");
                errors = errors + 1;
            end
            if (rxgot_n !== 0 || rx_starts !== 0 || rx_ends !== 0) begin
                $display("FAIL: bad IP header checksum produced an rx stream");
                errors = errors + 1;
            end
            if (stat_rx_udp !== s0) begin
                $display("FAIL: bad IP header checksum counted as received");
                errors = errors + 1;
            end
        end

        // ================= 10. counters ====================================
        $display("step 10: counter plausibility");
        if (stat_rx_frames !== 32'd7) begin
            $display("FAIL: stat_rx_frames = %0d, expected 7", stat_rx_frames);
            errors = errors + 1;
        end
        if (stat_rx_udp !== 32'd1) begin
            $display("FAIL: stat_rx_udp = %0d, expected 1", stat_rx_udp);
            errors = errors + 1;
        end
        if (stat_tx_frames !== 32'd6) begin
            $display("FAIL: stat_tx_frames = %0d, expected 6", stat_tx_frames);
            errors = errors + 1;
        end
        if (stat_rx_err !== 32'd2) begin
            $display("FAIL: stat_rx_err = %0d, expected 2", stat_rx_err);
            errors = errors + 1;
        end
        if (nframes !== 6) begin
            $display("FAIL: %0d transmit frames captured, expected 6", nframes);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("ETHPIPE SIM PASS");
            $finish;
        end else begin
            $display("ETHPIPE SIM FAIL: %0d check(s) failed", errors);
            $fatal(1, "tb_rmii_eth_pipe: checks failed");
        end
    end

    // FCS residue probe: report the CRC accumulator at every carrier end so the
    // expected residue constant can be calibrated against real frames.
    always @(posedge clk50) if (dut.rx_byte_end)
        $display("FCS end: crc=%08x hit=%b done_dg=%b ok=%b dbg=%054x",
                 dut.fcs_crc, dut.fcs_hit, dut.fcs_done_dg, dut.fcs_ok,
                 dut.dbg_frame);

    // ------------------------------------------------------------- watchdog --
    initial begin : watchdog
        #80_000_000;
        $display("FAIL: watchdog timeout");
        $fatal(1, "tb_rmii_eth_pipe: timeout");
    end

endmodule
