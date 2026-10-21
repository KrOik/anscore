`timescale 1ns/1ps

// Board-level endpoint regression for rsa_udp_min_endpoint.
// Drives a real RMII nibble stream (preamble + ARP request + UDP RSA request)
// into the receiver and decodes the RMII transmitter output, checking every
// byte of the ARP and UDP replies including the Ethernet FCS.
// This is the byte-level proof that the frames the UART "TX" event reports
// are well formed, independent of host-side packet capture.

module tb_rsa_udp_min_endpoint;

    localparam [47:0] FPGA_MAC = 48'h0600AABB0CDD;
    localparam [31:0] FPGA_IP  = {8'd192, 8'd168, 8'd137, 8'd15};
    localparam [47:0] HOST_MAC = 48'h84BA591684C2;
    localparam [31:0] HOST_IP  = {8'd192, 8'd168, 8'd137, 8'd1};

    localparam [255:0] MSG =
        256'h123456789ABCDEF00112233445566778899AABBCCDDEEFF00123456789ABCDEF;
    localparam [255:0] EXPECTED =
        256'hAEB8EDC48106703EE89EE3E6B9820CCAEB46B14A8768AB29D69519F296C2945A;

    reg clk50m = 1'b0;
    reg clk1m = 1'b0;
    reg rst_n = 1'b0;

    always #10 clk50m = ~clk50m;
    always #500 clk1m = ~clk1m;

    reg rx_crs = 1'b0;
    reg [1:0] rxd = 2'b00;
    wire [1:0] txd;
    wire txen;
    tri1 mdio;
    wire clk50m_out, ready, service_busy, rsa_busy, last_ok, last_error;
    wire mdc, phyrst;
    wire d_frame, d_ip, d_udp_proto, d_ps, d_arp, d_udp, d_ok, d_err, d_tx;

    rsa_udp_min_endpoint dut (
        .clk1m(clk1m),
        .rst_n(rst_n),
        .netrmii_clk50m(clk50m),
        .netrmii_rx_crs(rx_crs),
        .netrmii_rxd(rxd),
        .netrmii_mdc(mdc),
        .netrmii_txen(txen),
        .netrmii_mdio(mdio),
        .netrmii_txd(txd),
        .phyrst(phyrst),
        .clk50m(clk50m_out),
        .ready(ready),
        .service_busy(service_busy),
        .rsa_busy(rsa_busy),
        .last_ok(last_ok),
        .last_error(last_error),
        .debug_frame(d_frame),
        .debug_ip(d_ip),
        .debug_udp_proto(d_udp_proto),
        .debug_payload_start(d_ps),
        .debug_arp(d_arp),
        .debug_udp(d_udp),
        .debug_rsa_ok(d_ok),
        .debug_rsa_error(d_err),
        .debug_tx_udp(d_tx)
    );

    // ------------------------------------------------------------------
    // RMII stimulus / capture helpers
    // ------------------------------------------------------------------
    reg [7:0] tx_cap [0:2047];
    reg [7:0] req_buf [0:511];
    integer tx_cap_len;
    integer errors = 0;

    task rmii_send_byte(input [7:0] b);
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1) begin
                @(negedge clk50m);
                rxd <= b[2*k +: 2];
            end
        end
    endtask

    task rmii_send_frame(input integer n);
        // sends n bytes from req_buf plus 7x55 preamble + D5
        // dibit 0 of the first preamble byte is driven together with crs
        // so the receiver does not sample a spurious idle dibit
        integer i, k;
        reg [7:0] b;
        begin
            @(negedge clk50m);
            rx_crs <= 1'b1;
            rxd <= 2'b01;
            for (i = 0; i < 8 + n; i = i + 1) begin
                if (i < 7) b = 8'h55;
                else if (i == 7) b = 8'hD5;
                else b = req_buf[i - 8];
                for (k = 0; k < 4; k = k + 1) begin
                    if (i != 0 || k != 0) begin
                        @(negedge clk50m);
                        rxd <= b[2*k +: 2];
                    end
                end
            end
            @(negedge clk50m);
            rx_crs <= 1'b0;
            rxd <= 2'b00;
        end
    endtask

    // capture one full TX frame into tx_cap; returns payload+pad+FCS byte count
    task capture_tx;
        integer dibit_cnt;
        reg [7:0] sh;
        integer timeout;
        begin
            tx_cap_len = 0;
            dibit_cnt = 0;
            timeout = 0;
            // txen/txd change on posedge; sampling at negedge catches dibit 0
            while (!txen && timeout < 20000000) begin
                @(negedge clk50m);
                timeout = timeout + 1;
            end
            if (!txen) begin
                $display("ERROR: TX timeout waiting for txen");
                errors = errors + 1;
            end else begin
                while (txen) begin
                    case (dibit_cnt)
                        0: begin sh[1:0] = txd; dibit_cnt = 1; end
                        1: begin sh[3:2] = txd; dibit_cnt = 2; end
                        2: begin sh[5:4] = txd; dibit_cnt = 3; end
                        3: begin
                            sh[7:6] = txd;
                            tx_cap[tx_cap_len] = sh;
                            tx_cap_len = tx_cap_len + 1;
                            dibit_cnt = 0;
                            sh = 8'd0;
                        end
                    endcase
                    @(negedge clk50m);
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // CRC32 (Ethernet, reflected, init/xorout FFFFFFFF)
    // ------------------------------------------------------------------
    function automatic [31:0] crc32_byte(input [31:0] crc, input [7:0] d);
        reg [31:0] c;
        integer i;
        begin
            c = crc ^ {24'd0, d};
            for (i = 0; i < 8; i = i + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    task dump_cap(input integer n);
        integer i;
        begin
            for (i = 0; i < n && i < tx_cap_len; i = i + 1)
                $write("%02X ", tx_cap[i]);
            $display("");
        end
    endtask

    // locate SFD: index just after the 0xD5 that follows >=5 bytes of 0x55
    function automatic integer sfd_index;
        integer i, run;
        begin
            sfd_index = -1;
            run = 0;
            for (i = 0; i < tx_cap_len; i = i + 1) begin
                if (tx_cap[i] == 8'h55) run = run + 1;
                else if (tx_cap[i] == 8'hD5 && run >= 5) sfd_index = i + 1;
                else run = 0;
            end
        end
    endfunction

    task check_fcs(input integer base, input integer len);
        // len includes FCS; data = len-4 bytes starting at base
        reg [31:0] crc;
        reg [31:0] fcs;
        integer i;
        begin
            crc = 32'hFFFFFFFF;
            for (i = 0; i < len - 4; i = i + 1)
                crc = crc32_byte(crc, tx_cap[base + i]);
            crc = ~crc;
            fcs = {tx_cap[base+len-1], tx_cap[base+len-2],
                   tx_cap[base+len-3], tx_cap[base+len-4]};
            if (fcs !== crc) begin
                $display("ERROR: FCS mismatch got %08X want %08X", fcs, crc);
                errors = errors + 1;
            end else begin
                $display("  FCS ok %08X", fcs);
            end
        end
    endtask

    task expect8(input integer base, input [7:0] v, input [127:0] name);
        begin
            if (tx_cap[base] !== v) begin
                $display("ERROR: %0s @%0d got %02X want %02X", name, base, tx_cap[base], v);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // frame builders
    // ------------------------------------------------------------------
    function automatic [15:0] ip_cksum(input [15:0] id, input [15:0] len);
        reg [31:0] s;
        begin
            s = 16'h4500 + len + id + 16'h4000 + 16'h4011
              + HOST_IP[31:16] + HOST_IP[15:0] + FPGA_IP[31:16] + FPGA_IP[15:0];
            s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
            s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
            ip_cksum = ~s[15:0];
        end
    endfunction

    integer bi;
    task putb(input [7:0] b); begin req_buf[bi] = b; bi = bi + 1; end endtask
    task putm(input [47:0] m); integer k; begin for (k=5;k>=0;k=k-1) putb(m[8*k +: 8]); end endtask
    task put32(input [31:0] v); integer k; begin for (k=3;k>=0;k=k-1) putb(v[8*k +: 8]); end endtask

    task build_arp_request;
        begin
            bi = 0;
            putm(48'hFFFFFFFFFFFF);   // dst broadcast
            putm(HOST_MAC);           // src
            putb(8'h08); putb(8'h06); // ARP
            putb(8'h00); putb(8'h01); // htype
            putb(8'h08); putb(8'h00); // ptype
            putb(8'h06); putb(8'h04); // hlen/plen
            putb(8'h00); putb(8'h01); // oper = request
            putm(HOST_MAC);           // SHA
            put32(HOST_IP);           // SPA
            putm(48'd0);              // THA
            put32(FPGA_IP);           // TPA
        end
    endtask

    task build_udp_request;
        reg [15:0] ck;
        integer i;
        begin
            bi = 0;
            putm(FPGA_MAC);           // dst
            putm(HOST_MAC);           // src
            putb(8'h08); putb(8'h00); // IPv4
            putb(8'h45); putb(8'h00);
            putb(8'h00); putb(8'h41); // total len 65
            putb(8'h12); putb(8'h34); // id
            putb(8'h40); putb(8'h00); // flags
            putb(8'h40); putb(8'h11); // ttl/proto
            ck = ip_cksum(16'h1234, 16'h0041);
            putb(ck[15:8]); putb(ck[7:0]);
            put32(HOST_IP);
            put32(FPGA_IP);
            putb(8'h13); putb(8'h88); // src port 5000
            putb(8'h2C); putb(8'hBB); // dst port 11451
            putb(8'h00); putb(8'h2D); // len 45
            putb(8'h00); putb(8'h00); // udp cksum 0
            putb("R"); putb("S"); putb("A"); putb("1");
            putb(8'h01);
            for (i = 31; i >= 0; i = i - 1) putb(MSG[8*i +: 8]);
        end
    endtask

    // ------------------------------------------------------------------
    // checks
    // ------------------------------------------------------------------
    task check_arp_reply;
        integer base, len, i;
        begin
            base = sfd_index();
            if (base < 0) begin
                $display("ERROR: no SFD in ARP reply"); errors = errors + 1;
                dump_cap(64);
            end else begin
                len = tx_cap_len - base;
                $display("ARP reply frame bytes=%0d (incl FCS)", len);
                check_fcs(base, len);
                for (i = 0; i < 6; i = i + 1) expect8(base+i,     HOST_MAC[8*(5-i) +: 8], "arp dst mac");
                for (i = 0; i < 6; i = i + 1) expect8(base+6+i,   FPGA_MAC[8*(5-i) +: 8], "arp src mac");
                expect8(base+12, 8'h08, "arp type hi");
                expect8(base+13, 8'h06, "arp type lo");
                expect8(base+20, 8'h00, "arp oper hi");
                expect8(base+21, 8'h02, "arp oper reply");
                for (i = 0; i < 6; i = i + 1) expect8(base+22+i, FPGA_MAC[8*(5-i) +: 8], "arp sha");
                for (i = 0; i < 4; i = i + 1) expect8(base+28+i, FPGA_IP[8*(3-i) +: 8], "arp spa");
                for (i = 0; i < 6; i = i + 1) expect8(base+32+i, HOST_MAC[8*(5-i) +: 8], "arp tha");
                for (i = 0; i < 4; i = i + 1) expect8(base+38+i, HOST_IP[8*(3-i) +: 8], "arp tpa");
                $display("ARP reply field check done");
            end
        end
    endtask

    task check_udp_reply;
        integer base, len, i;
        reg [255:0] got_ct;
        reg [15:0] rx_ck;
        begin
            base = sfd_index();
            if (base < 0) begin
                $display("ERROR: no SFD in UDP reply"); errors = errors + 1;
            end else begin
                len = tx_cap_len - base;
                $display("UDP reply frame bytes=%0d (incl FCS)", len);
                check_fcs(base, len);
                for (i = 0; i < 6; i = i + 1) expect8(base+i,   HOST_MAC[8*(5-i) +: 8], "udp dst mac");
                for (i = 0; i < 6; i = i + 1) expect8(base+6+i, FPGA_MAC[8*(5-i) +: 8], "udp src mac");
                expect8(base+12, 8'h08, "eth type hi");
                expect8(base+13, 8'h00, "eth type lo");
                expect8(base+14, 8'h45, "ip ver ihl");
                expect8(base+16, 8'h00, "ip len hi");
                expect8(base+17, 8'd68, "ip len lo");
                expect8(base+22, 8'h40, "ip ttl");
                expect8(base+23, 8'h11, "ip proto udp");
                rx_ck = {tx_cap[base+24], tx_cap[base+25]};
                if (rx_ck !== ip_cksum({tx_cap[base+18], tx_cap[base+19]}, 16'd68)) begin
                    $display("ERROR: reply IP checksum %04X", rx_ck);
                    errors = errors + 1;
                end else $display("  reply IP checksum ok %04X", rx_ck);
                for (i = 0; i < 4; i = i + 1) expect8(base+26+i, FPGA_IP[8*(3-i) +: 8], "ip src");
                for (i = 0; i < 4; i = i + 1) expect8(base+30+i, HOST_IP[8*(3-i) +: 8], "ip dst");
                expect8(base+34, 8'h2C, "udp sport hi");
                expect8(base+35, 8'hBB, "udp sport lo");
                expect8(base+36, 8'h13, "udp dport hi");
                expect8(base+37, 8'h88, "udp dport lo");
                expect8(base+38, 8'h00, "udp len hi");
                expect8(base+39, 8'd48, "udp len lo");
                expect8(base+42, "R", "magic0");
                expect8(base+43, "S", "magic1");
                expect8(base+44, "A", "magic2");
                expect8(base+45, "R", "magic3");
                expect8(base+46, 8'd0, "status ok");
                expect8(base+49, 8'd32, "width 32");
                for (i = 0; i < 32; i = i + 1)
                    got_ct[8*(31-i) +: 8] = tx_cap[base+50+i];
                if (got_ct !== EXPECTED) begin
                    $display("ERROR: ciphertext mismatch");
                    $display("  got  %064X", got_ct);
                    $display("  want %064X", EXPECTED);
                    errors = errors + 1;
                end else begin
                    $display("  ciphertext ok %064X", got_ct);
                end
                $display("UDP reply field check done");
            end
        end
    endtask

    // ------------------------------------------------------------------
    // stimulus
    // ------------------------------------------------------------------
    initial begin
        rst_n = 1'b0;
        #2000;
        rst_n = 1'b1;
        // bypass the SMI/MDIO PHY bring-up; we are testing the packet path
        force dut.phy_rdy = 1'b1;
        #2000;

        $display("=== ARP request ===");
        build_arp_request();
        rmii_send_frame(42);
        capture_tx();
        check_arp_reply();

        repeat (200) @(posedge clk50m);

        $display("=== UDP RSA request ===");
        build_udp_request();
        rmii_send_frame(bi);
        capture_tx();
        check_udp_reply();

        if (errors == 0) $display("TB PASS");
        else $display("TB FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #200000000; // 200 ms wall-clock guard (RSA modexp is long)
        $display("ERROR: global timeout");
        $finish;
    end

endmodule
