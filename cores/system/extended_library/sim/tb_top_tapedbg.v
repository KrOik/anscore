// tb_top_tapedbg -- end-to-end simulation of the tapeout-debug top:
// drives uart_rx with the W/R/P/T vector protocol and checks every
// checklist facility: POR regs, PLL, clock mux/gate/step, golden unit +
// shadow checker + trigger, MBIST (+ fault injection + host port), scan
// chain (reg-driven and TAP-driven), JTAG TAP (IDCODE/SAMPLE/SCAN/BYPASS),
// mini-ILA, pipeline bypass, UART loopback, POR retrigger, test-port lock.
`timescale 1ns/1ps
module tb_top_tapedbg;
    reg clk = 0;
    wire tx, sp, sf;
    reg  rxd = 1;
    wire [7:0] dbg;
    always #18.5 clk = ~clk;   // ~27 MHz

    top_tapedbg #(.TICK_WIN(25'd100_000)) dut (
        .clk(clk), .uart_rx_pin(rxd), .uart_tx(tx),
        .status_pass(sp), .status_fail(sf),
        .dbg7(dbg[7]), .dbg6(dbg[6]), .dbg5(dbg[5]), .dbg4(dbg[4]),
        .dbg3(dbg[3]), .dbg2(dbg[2]), .dbg1(dbg[1]), .dbg0(dbg[0]));

    // ---- UART byte send task (115200 @27MHz) ----
    localparam integer BIT_NS = 8680;
    task txb(input [7:0] b);
        integer k;
        begin
            rxd = 0; #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                rxd = b[k]; #(BIT_NS);
            end
            rxd = 1; #(BIT_NS);
            #(BIT_NS);
        end
    endtask
    task cmd_W(input [7:0] a, input [31:0] d);
        begin txb(8'h57); txb(a); txb(d[7:0]); txb(d[15:8]);
              txb(d[23:16]); txb(d[31:24]); end
    endtask
    task cmd_R(input [7:0] a);
        begin txb(8'h52); txb(a); end
    endtask
    task cmd_T; begin txb(8'h54); end endtask

    // ---- UART decode of dut.tx ----
    localparam integer BIT_CLKS = 234;
    reg [7:0] rxq [0:16383];
    integer nrx = 0;
    integer bitcnt = 0;
    reg [9:0] shreg = 10'h3FF;
    reg rx_busy = 0;
    always @(posedge clk) begin
        if (!rx_busy && tx === 1'b0) begin
            rx_busy <= 1; bitcnt <= 0;
        end else if (rx_busy) begin
            bitcnt <= bitcnt + 1;
            if ((bitcnt % BIT_CLKS) == BIT_CLKS/2)
                shreg <= {tx, shreg[9:1]};
            if (bitcnt == 10*BIT_CLKS - BIT_CLKS/2 + 1) begin
                rx_busy <= 0;
                rxq[nrx] <= shreg[8:1];
                nrx <= nrx + 1;
            end
        end
    end

    function [31:0] qhex;
        input integer idx, off; integer k; reg [7:0] c; reg [3:0] n;
        begin
            qhex = 0;
            for (k = 0; k < 8; k = k + 1) begin
                c = rxq[idx + off + k];
                n = (c >= "A") ? (c - "A" + 10) : (c - "0");
                qhex = {qhex[27:0], n};
            end
        end
    endfunction

    integer errs = 0;
    integer ntest = 0;
    task chk(input [255:0] name, input cond, input [31:0] val);
        begin
            ntest = ntest + 1;
            if (!cond) begin
                errs = errs + 1;
                $display("FAIL %0s (got %08x)", name, val);
            end else begin
                $display("PASS %0s (%08x)", name, val);
            end
        end
    endtask

    // read register via UART; waits for the 12-byte "R=XXXXXXXX\r\n" reply
    reg [31:0] rdv;
    task read_reg(input [7:0] a);
        integer base, tmo;
        begin
            base = nrx;
            cmd_R(a);
            tmo = 0;
            while (nrx < base + 12 && tmo < 2000000) begin
                #(BIT_NS); tmo = tmo + 1;
            end
            if (nrx < base + 12) begin
                rdv = 32'hEEEEEEEE;
                errs = errs + 1;
                $display("FAIL read_reg timeout a=%02x", a);
            end else begin
                rdv = qhex(base, 2);
            end
        end
    endtask

    // JTAG bit-bang: one TCK cycle with given TMS/TDI
    task jt(input tms, input tdi);
        begin cmd_W(8'h0A, {29'd0, 1'b1, tdi, tms}); end
    endtask
    // read TDO (reg 0x0A bit5) and TAP state (bits[4:1])
    task read_tdo;
        begin read_reg(8'h0A); end
    endtask

    integer i, base;
    reg [31:0] v, v2;
    reg [63:0] shift_in, shift_out, tap_dr;
    reg [15:0] sav_cnt;

    // golden-model replicate of dbg_pipe3 transforms
    function [15:0] f0; input [15:0] x; begin f0 = {x[14:0], x[15]} + 16'h1021; end endfunction
    function [15:0] f1; input [15:0] x; begin f1 = (x ^ 16'h5A5A) + 16'd3;      end endfunction
    function [15:0] f2; input [15:0] x; begin f2 = ~x + {8'd0, x[7:0]};         end endfunction

    initial begin
        rxd = 1;
        #(700000);                              // POR + settle (~19k clks)

        // ---------- T5 bus sanity ----------
        read_reg(8'h1F); chk("magic TAPE", rdv == 32'h54415045, rdv);
        cmd_W(8'h00, 32'hDEADBEEF); #(BIT_NS*20);
        read_reg(8'h00); chk("scratch rw", rdv == 32'hDEADBEEF, rdv);
        read_reg(8'hF0); chk("invalid addr", rdv == 32'hDEAD00F0, rdv);

        // ---------- A18/A7: POR + reset status ----------
        read_reg(8'h10);
        chk("por_cycles=4096", rdv[15:0] == 16'd4096, rdv);
        chk("por_count=0",    rdv[31:24] == 8'd0,   rdv);
        chk("rst_glitch=0",   rdv[23] == 1'b0,      rdv);

        // ---------- A6: PLL ----------
        read_reg(8'h11);
        chk("pll lock seen", rdv[31] == 1'b1, rdv);
        chk("pll locked",    rdv[30] == 1'b1, rdv);

        // ---------- A1 boot: scan self-check ----------
        read_reg(8'h09);
        chk("scan boot ok", rdv[2] == 1'b1, rdv);

        // ---------- A2: MBIST auto-run ----------
        i = 0;
        read_reg(8'h18);
        while (rdv[18] !== 1'b1 && i < 200) begin
            read_reg(8'h18); i = i + 1;
        end
        chk("mbist done", rdv[18] == 1'b1, rdv);
        chk("mbist nofail", rdv[17] == 1'b0, rdv);

        // ---------- A9: golden unit ----------
        i = 0;
        read_reg(8'h15);
        while (rdv[31] !== 1'b1 && i < 200) begin
            read_reg(8'h15); i = i + 1;
        end
        chk("golden done",  rdv[31] == 1'b1, rdv);
        chk("golden match", rdv[30] == 1'b1, rdv);
        chk("golden no err", rdv[28] == 1'b0, rdv);
        read_reg(8'h14); chk("golden digest", rdv == 32'hDB2D98F1, rdv);

        // ---------- A17: UART TX loopback ----------
        read_reg(8'h1E);
        chk("lb bytes seen", rdv[23:16] > 8'd0, rdv);
        chk("lb last=\\n",   rdv[15:8] == 8'h0A, rdv);
        chk("lb no ferr",    rdv[27] == 1'b0, rdv);

        // ---------- A10: pipeline + bypass ----------
        cmd_W(8'h0E, 32'd0);
        cmd_W(8'h0D, 32'h0001_1234);           // kick din=0x1234
        #(BIT_NS*50);
        read_reg(8'h1B);
        chk("pipe y0", rdv[31:16] == f0(16'h1234), rdv);
        chk("pipe y1", rdv[15:0]  == f1(f0(16'h1234)), rdv);
        read_reg(8'h1C);
        chk("pipe y2", rdv[31:16] == f2(f1(f0(16'h1234))), rdv);
        cmd_W(8'h0E, 32'd7);                   // bypass all
        cmd_W(8'h0D, 32'h0001_1234);
        #(BIT_NS*50);
        read_reg(8'h1B);
        chk("pipe byp y0", rdv[31:16] == 16'h1234, rdv);
        chk("pipe byp y1", rdv[15:0]  == 16'h1234, rdv);
        read_reg(8'h1C);
        chk("pipe byp y2", rdv[31:16] == 16'h1234, rdv);
        cmd_W(8'h0E, 32'd0);

        // ---------- A14: RAM direct access ----------
        cmd_W(8'h0F, 32'h0001_55A5);           // h_we addr=0x55 data=0xA5
        cmd_W(8'h0F, 32'h0002_5500);           // h_re addr=0x55
        #(BIT_NS*20);
        read_reg(8'h0F);
        chk("ram host rd", rdv[7:0] == 8'hA5, rdv);

        // ---------- A7/A12/A15: domain reset + clock gate + step ----------
        cmd_W(8'h03, 32'd1);                   // hold dclk domain in reset
        cmd_W(8'h05, 32'd2);                   // step_mode=1, gate_en=0
        cmd_W(8'h03, 32'd0);                   // release reset; domain frozen
        #(BIT_NS*50);
        read_reg(8'h17); sav_cnt = rdv[15:0];
        chk("gate frozen a", sav_cnt == 16'd0, rdv);
        #(BIT_NS*200);
        read_reg(8'h17);
        chk("gate frozen b", rdv[15:0] == sav_cnt, rdv);
        cmd_W(8'h02, 32'd2);                   // single step
        #(BIT_NS*100);
        read_reg(8'h17);
        chk("step -> cnt1", rdv[15:0] == 16'd1, rdv);
        cmd_W(8'h02, 32'd2);
        cmd_W(8'h02, 32'd2);
        #(BIT_NS*100);
        read_reg(8'h17);
        chk("step x3 -> cnt3", rdv[15:0] == 16'd3, rdv);
        cmd_W(8'h05, 32'd1);                   // gate_en=1, free run
        i = 0;
        read_reg(8'h15);
        while (rdv[31] !== 1'b1 && i < 300) begin
            read_reg(8'h15); i = i + 1;
        end
        chk("golden rerun done", rdv[31] == 1'b1, rdv);
        read_reg(8'h14); chk("golden rerun digest", rdv == 32'hDB2D98F1, rdv);

        // ---------- A5: clock bypass mux ----------
        cmd_W(8'h04, 32'd1);                   // dclk <- 54 MHz
        i = 0;
        read_reg(8'h15);
        while (rdv[31] !== 1'b1 && i < 300) begin
            read_reg(8'h15); i = i + 1;
        end
        read_reg(8'h14); chk("digest @54MHz", rdv == 32'hDB2D98F1, rdv);
        cmd_W(8'h04, 32'd2);                   // dclk <- 13.5 MHz
        i = 0;
        read_reg(8'h15);
        while (rdv[31] !== 1'b1 && i < 400) begin
            read_reg(8'h15); i = i + 1;
        end
        read_reg(8'h14); chk("digest @13.5MHz", rdv == 32'hDB2D98F1, rdv);
        cmd_W(8'h04, 32'd0);                   // back to 27 MHz
        i = 0;
        read_reg(8'h15);
        while (rdv[31] !== 1'b1 && i < 300) begin
            read_reg(8'h15); i = i + 1;
        end

        // ---------- A13: ring oscillator alive ----------
        read_reg(8'h13);
        chk("ro alive", rdv[24] == 1'b1, rdv);

        // ---------- A11+B2: ILA trigger on fault ----------
        cmd_W(8'h0B, 32'h00000200);            // cfg0 trig_mask = 0x80
        cmd_W(8'h0B, 32'h00000201);            // cfg1 trig_val  = 0x80
        cmd_W(8'h0B, 32'h00000022);            // cfg2 pre_trig  = 8
        cmd_W(8'h0B, 32'h00000007);            // cfg3 trig_mode = rising
        cmd_W(8'h0B, 32'h00040000);            // arm
        cmd_W(8'h06, 32'd1);                   // fi_golden
        cmd_W(8'h03, 32'd1);                   // domain reset -> rerun
        cmd_W(8'h03, 32'd0);
        i = 0;
        read_reg(8'h1D);
        while (rdv[30] !== 1'b1 && i < 300) begin
            read_reg(8'h1D); i = i + 1;
        end
        chk("ila done",  rdv[30] == 1'b1, rdv);
        chk("ila fired", rdv[29] == 1'b1, rdv);
        v = rdv[9:0];                          // trig_ptr
        cmd_W(8'h0C, v);                       // rd_addr = trig_ptr
        #(BIT_NS*20);
        read_reg(8'h0C);
        chk("ila trig sample bit7", rdv[7] == 1'b1, rdv);
        cmd_W(8'h0C, (v - 1) & 10'h3FF);
        #(BIT_NS*20);
        read_reg(8'h0C);
        chk("ila pre-trig bit7=0", rdv[7] == 1'b0, rdv);

        // ---------- B2: first-mismatch context ----------
        read_reg(8'h15);
        chk("first_err",      rdv[28] == 1'b1, rdv);
        chk("trig_sticky",    rdv[27] == 1'b1, rdv);
        chk("mis_cnt>0",      rdv[15:0] > 16'd0, rdv);
        read_reg(8'h16);
        chk("err exp^got=FF", (rdv[31:16] ^ rdv[15:0]) == 16'h00FF, rdv);
        read_reg(8'h17);
        chk("err_cyc small", rdv[31:16] < 16'd10, rdv);

        // clear fault, rerun clean
        cmd_W(8'h06, 32'd0);
        cmd_W(8'h03, 32'd1);
        cmd_W(8'h03, 32'd0);
        i = 0;
        read_reg(8'h15);
        while (rdv[31] !== 1'b1 && i < 300) begin
            read_reg(8'h15); i = i + 1;
        end
        chk("clean rerun done",  rdv[31] == 1'b1, rdv);
        chk("clean first_err=0", rdv[28] == 1'b0, rdv);
        read_reg(8'h14); chk("clean digest", rdv == 32'hDB2D98F1, rdv);

        // ---------- A2 fault injection: stuck RAM cell ----------
        cmd_W(8'h06, 32'd2);                   // fi_mbist
        cmd_W(8'h07, 32'h00000042);            // fi_addr = 0x42
        cmd_W(8'h08, 32'd1);                   // start
        i = 0;
        read_reg(8'h18);
        while (rdv[18] !== 1'b1 && i < 300) begin
            read_reg(8'h18); i = i + 1;
        end
        chk("mbist fi fail",   rdv[17] == 1'b1, rdv);
        chk("mbist fi addr",   rdv[7:0] == 8'h42, rdv);
        chk("mbist fi phase1", rdv[15:12] == 4'd1, rdv);
        read_reg(8'h19);
        chk("mbist exp AA", rdv[31:24] == 8'hAA, rdv);
        chk("mbist got 55", rdv[23:16] == 8'h55, rdv);
        cmd_W(8'h06, 32'd0);
        cmd_W(8'h08, 32'd1);
        i = 0;
        read_reg(8'h18);
        while (rdv[18] !== 1'b1 && i < 300) begin
            read_reg(8'h18); i = i + 1;
        end
        chk("mbist clean", rdv[17] == 1'b0, rdv);

        // ---------- A1: register-driven scan shift ----------
        shift_in = 64'hCAFE_BABE_1234_5678;
        cmd_W(8'h09, 32'd1);                   // se=1, si=0
        for (i = 0; i < 64; i = i + 1)
            cmd_W(8'h09, 32'd1 | ({31'd0, shift_in[i]} << 1) | 32'd8);
        shift_out = 64'd0;
        for (i = 0; i < 64; i = i + 1) begin
            read_reg(8'h09);                   // read so BEFORE stepping
            shift_out[i] = rdv[0];
            cmd_W(8'h09, 32'd9);               // se=1, si=0, step
        end
        chk("scan loopback", shift_out == shift_in, shift_out[31:0]);

        // stuck-cell injection: a stuck-at-0 at cell[3] blocks every 1 from
        // propagating past it, so all-ones in -> all-zeros out (fault sig)
        cmd_W(8'h06, 32'd4);                   // fi_scan_stuck
        for (i = 0; i < 64; i = i + 1)
            cmd_W(8'h09, 32'd1 | 32'd2 | 32'd8); // se=1 si=1 step
        shift_out = 64'd0;
        for (i = 0; i < 64; i = i + 1) begin
            read_reg(8'h09);
            shift_out[i] = rdv[0];
            cmd_W(8'h09, 32'd9);
        end
        chk("scan stuck det", shift_out == 64'd0, shift_out[31:0]);
        cmd_W(8'h06, 32'd0);
        cmd_W(8'h09, 32'd0);                   // se=0

        // ---------- A3: JTAG TAP bit-bang ----------
        // reset to RTI, then IR <- IDCODE
        jt(1,0); jt(1,0); jt(1,0); jt(1,0); jt(1,0);   // -> TLR
        jt(0,0);                                        // RTI
        jt(1,0); jt(1,0);                               // SDR, SIR
        jt(0,0); jt(0,0);                               // CIR, SHIR
        jt(0,1); jt(0,0); jt(0,0); jt(1,0);             // IR=0001 (IDCODE)
        jt(1,0);                                        // UIR
        jt(0,0);                                        // RTI
        jt(1,0); jt(0,0); jt(0,0);                      // SDR, CDR, SHDR
        tap_dr = 64'd0;
        for (i = 0; i < 32; i = i + 1) begin
            read_reg(8'h0A);
            tap_dr[i] = rdv[5];
            jt((i == 31), 0);
        end
        chk("tap idcode", tap_dr[31:0] == 32'h54414E47, tap_dr[31:0]);

        // IR <- SAMPLE, capture status_vec, shift out
        jt(1,0);                                        // UDR
        jt(1,0); jt(1,0);                               // SDR, SIR
        jt(0,0); jt(0,0);                               // CIR, SHIR
        jt(0,0); jt(0,0); jt(0,1); jt(1,0);             // IR=0100 (SAMPLE)
        jt(1,0); jt(0,0);                               // UIR, RTI
        jt(1,0); jt(0,0); jt(0,0);                      // SDR, CDR, SHDR
        tap_dr = 64'd0;
        for (i = 0; i < 64; i = i + 1) begin
            read_reg(8'h0A);
            tap_dr[i] = rdv[5];
            jt((i == 63), 0);
        end
        chk("tap sample por", tap_dr[55:40] == 16'd4096, tap_dr[55:40]);

        // IR <- SCAN: TAP drives the 64-bit chain; verify por_cycles field
        jt(1,0);                                        // UDR
        jt(1,0); jt(1,0);                               // SDR, SIR
        jt(0,0); jt(0,0);                               // CIR, SHIR
        jt(0,0); jt(0,1); jt(0,0); jt(1,0);             // IR=0010 (SCAN)
        jt(1,0); jt(0,0);                               // UIR, RTI
        jt(1,0); jt(0,0); jt(0,0);                      // SDR, CDR(chain cap), SHDR
        tap_dr = 64'd0;
        for (i = 0; i < 64; i = i + 1) begin
            read_reg(8'h0A);
            tap_dr[63 - i] = rdv[5];                    // MSB first out
            jt((i == 63), 0);
        end
        chk("tap scan por", tap_dr[55:40] == 16'd4096, {16'd0, tap_dr[55:40]});
        jt(1,0); jt(0,0);                               // UDR, RTI

        // ---------- A18: POR retrigger ----------
        cmd_W(8'h01, 32'd8);                   // por_bit = 8 (256 clks)
        cmd_W(8'h02, 32'd1);                   // retrigger
        #(BIT_NS*400);
        read_reg(8'h10);
        chk("retrig por_cycles", rdv[15:0] == 16'd256, rdv);
        chk("retrig por_count",  rdv[31:24] == 8'd1,   rdv);
        chk("retrig no glitch",  rdv[23] == 1'b0,      rdv);
        // engines re-ran after reset
        i = 0;
        read_reg(8'h15);
        while (rdv[31] !== 1'b1 && i < 300) begin
            read_reg(8'h15); i = i + 1;
        end
        read_reg(8'h14); chk("post-por digest", rdv == 32'hDB2D98F1, rdv);
        read_reg(8'h18); chk("post-por mbist", rdv[18] == 1'b1 && rdv[17] == 1'b0, rdv);

        // ---------- status pins ----------
        chk("status_pass pin", sp === 1'b1, {31'd0, sp});
        chk("status_fail pin", sf === 1'b0, {31'd0, sf});

        // ---------- A16: test-port lock (LAST -- blocks all writes) ----------
        read_reg(8'h00); v = rdv;
        cmd_W(8'h02, 32'd4);                   // test_lock = 1
        cmd_W(8'h00, 32'h12345678);            // must be ignored
        #(BIT_NS*50);
        read_reg(8'h00);
        chk("lock blocks W", rdv == v, rdv);
        read_reg(8'h11);
        chk("lock bit set", rdv[13] == 1'b1, rdv);

        // ---------- 'T' report smoke ----------
        base = nrx;
        cmd_T;
        i = 0;
        while (nrx < base + 16*13 && i < 3000000) begin
            #(BIT_NS); i = i + 1;
        end
        chk("T report 16x13B", nrx >= base + 16*13, nrx - base);
        chk("T magic line", qhex(base + 15*13, 3) == 32'h54415045,
            qhex(base + 15*13, 3));

        if (errs == 0) $display("TAPEDBG TB PASS (%0d checks)", ntest);
        else           $display("TAPEDBG TB FAIL: %0d/%0d errors", errs, ntest);
        $finish;
    end

    initial begin
        #3_000_000_000;                        // global timeout 3 s
        $display("TAPEDBG TB TIMEOUT");
        $finish;
    end
endmodule
