// ============================================================================
// top_tapedbg -- ASIC-tapeout debug-infrastructure verification top.
//
// Implements the dock-executable subset of docs/ASIC_TAPEOUT_DEBUG_CHECKLIST.md
// on the wave2 hwverify harness (UART W/R/P/T + 8-bit LA probe bus):
//
//   A1  scan chain          dft_scan_chain (64 FF, capture+shift, UART or TAP)
//   A2  MBIST               mem_bist + w2_dpram, auto-run at boot, host R/W port
//   A3  JTAG TAP            tap_mini (BYPASS/IDCODE/SAMPLE/SCAN), reg bit-bang
//   A4  debug mux           probe_sel -> dbg[6:0]; dbg7 = trigger-out (B2)
//   A5  clock bypass mux    clk_sel: 27 MHz / rPLL 54 MHz / 13.5 MHz -> dclk
//   A6  PLL/clock observe   lock+latency regs; divided clocks on probe pages
//   A7  domain resets       dom_rst[3:0] + POR status regs
//   A8  fault injection     fi_* regs: golden ALU xor, MBIST stuck, scan stuck
//   A9  golden unit         golden_ref + shadow checker -> digest + trig
//   A10 pipe bypass         dbg_pipe3, per-stage bypass, stage regs readable
//   A11 mini-ILA            ila_core on the dbg bus, UART-configured/read out
//   A12 clock single-step   step_mode + step pulse into dclk domain
//   A13 ring oscillator     ring_osc + divider + windowed edge counter
//   A14 RAM direct access   mem_bist host port via regs
//   A15 clk-gate override   cg_override forces all domain clk_en high
//   A16 test-port lock      test_lock sticky (POR-surviving) blocks 'W' writes
//   A17 IO loopback         uart_tx tapped into second uart_rx (self-echo)
//   A18 programmable POR    por_bit reg + por_retrig re-run LA-visible boot
//
//   B2  stimulus checker    shadow model + first-mismatch latch + trig strobe
//   B3  programmable clock  rPLL + dividers observable on dbg pages
//   B7  vector protocol     'W'/'R'/'P'/'T' command stream (as top_hwverify)
//
// UART (115200 8N1, rx=T13, tx=M11):
//   'W' a d0 d1 d2 d3 -> regs[a] = {d3,d2,d1,d0} (d0 = LSB first)
//   'R' a             -> "R=XXXXXXXX\r\n"
//   'P' s             -> probe page select
//   'T'               -> 16-reg status report (regs 0x10..0x1F)
//
// dbg[7:0] LA bus: A11 B11 N6 D11 N9 N7 L9 N8 (LA-Dn <- dbg(7-n)).
// dbg7 is ALWAYS the trigger-out line (LA channel D0) so the analyser has a
// stable trigger regardless of the selected page.
// ============================================================================
module top_tapedbg #(
    parameter [24:0] TICK_WIN    = 25'd27_000_000,
    parameter [31:0] GOLD_DIGEST = 32'hDB2D98F1,  // golden_ref sim-verified
    parameter [15:0] GOLD_CYCLES = 16'd4096
)(
    input  wire clk,            // H11, 27 MHz
    input  wire uart_rx_pin,    // T13
    output wire uart_tx,        // M11
    output wire status_pass,    // T9
    output wire status_fail,    // P9
    output wire dbg7,           // A11 = trigger-out (LA D0)
    output wire dbg6,           // B11
    output wire dbg5,           // N6
    output wire dbg4,           // D11
    output wire dbg3,           // N9
    output wire dbg2,           // N7
    output wire dbg1,           // L9
    output wire dbg0            // N8
);

// forward decls for the command engine
reg        cmd_we;
reg        cmd_re;
reg        cmd_rep;
reg [7:0]  cmd_addr;
reg [31:0] cmd_wdata;

// ==================== A18: programmable POR =================================
// always-on domain (no reset): por_bit, por_count, test_lock, clk_sel must
// survive a re-triggered POR, otherwise a soft reset would erase the very
// knobs the host set to observe the boot.
reg [25:0] reset_count = 26'd0;
reg        rst_n_r     = 1'b0;
reg [4:0]  por_bit     = 5'd12;
reg [7:0]  por_count   = 8'd0;
reg        test_lock   = 1'b0;
reg [1:0]  clk_sel     = 2'd0;
reg [15:0] por_cycles  = 16'd0;

wire [4:0]  por_bit_eff = (por_bit < 5'd4) ? 5'd4 : por_bit;  // clamp min
wire [25:0] por_target  = (26'd1 << por_bit_eff);
// rst_n is a registered flag: changing por_bit mid-run only affects the
// NEXT POR window, it can never pull rst_n down by itself (that was the
// original reset_count[por_bit] bug -- a live bit-select re-triggered
// the reset the moment a shorter length was written).
wire rst_n = rst_n_r;

wire wr_ok      = cmd_we && !test_lock;            // A16: lock kills writes
wire por_trig   = wr_ok && (cmd_addr == 8'h02) && cmd_wdata[0];
wire lock_set   = wr_ok && (cmd_addr == 8'h02) && cmd_wdata[2];

always @(posedge clk) begin
    if (por_trig) begin
        rst_n_r     <= 1'b0;
        reset_count <= 26'd0;
        por_count   <= por_count + 8'd1;
        por_cycles  <= 16'd0;
    end else if (!rst_n_r) begin
        if (reset_count == por_target - 26'd1) rst_n_r <= 1'b1;
        else reset_count <= reset_count + 26'd1;
        por_cycles <= por_cycles + 16'd1;
    end
    if (lock_set)  test_lock <= 1'b1;
    if (wr_ok && (cmd_addr == 8'h01)) por_bit <= cmd_wdata[4:0];
    if (wr_ok && (cmd_addr == 8'h04)) clk_sel <= cmd_wdata[1:0];
end

// reset synchronisation + glitch watch (glitch = unexpected re-assertion)
reg rst_s1 = 1'b0, rst_s2 = 1'b0;
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin rst_s1 <= 1'b0; rst_s2 <= 1'b0; end
    else      begin rst_s1 <= 1'b1; rst_s2 <= rst_s1; end

reg rst_ever = 1'b0, rst_glitch = 1'b0, por_exp = 1'b0;
always @(posedge clk) begin
    // por_trig must win over the running rst_s2=1 level, otherwise the
    // expected-reset mask is cleared on the very edge it is needed for
    if (por_trig)      por_exp <= 1'b1;
    else if (rst_s2)   por_exp <= 1'b0;
    if (rst_s2) rst_ever <= 1'b1;
    if (rst_ever && !rst_s1 && !por_exp) rst_glitch <= 1'b1;
end

// ==================== A7: per-domain soft reset ==============================
reg [3:0] dom_rst;
always @(posedge clk or negedge rst_n)
    if (!rst_n) dom_rst <= 4'd0;
    else if (wr_ok && (cmd_addr == 8'h03)) dom_rst <= cmd_wdata[3:0];

// ==================== A6: rPLL 27 -> 54 MHz, lock observable =================
wire clk54, pll_lock;
rPLL #(
    .FCLKIN("27.0"), .IDIV_SEL(0), .FBDIV_SEL(1), .ODIV_SEL(16)
) u_pll (
    .CLKOUT(clk54), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
    .LOCK(pll_lock), .CLKIN(clk), .CLKFB(1'b0), .FBDSEL(6'b0),
    .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0),
    .FDLY(4'b0), .RESET(~rst_n), .RESET_P(1'b0));

reg [15:0] pll_lock_cycles = 16'd0;
reg        pll_lock_seen   = 1'b0;
always @(posedge clk)
    if (rst_n && !pll_lock_seen) begin
        if (!pll_lock) pll_lock_cycles <= pll_lock_cycles + 16'd1;
        else           pll_lock_seen   <= 1'b1;
    end

// clk54 frequency counter over a 27 MHz TICK_WIN gate (B3/A6)
reg        m_run = 1'b0, m_done = 1'b0;
reg [24:0] m_win = 25'd0, clk54_ticks = 25'd0;
reg  [1:0] md54_s = 2'b00;
always @(posedge clk) begin
    if (rst_n && pll_lock && !m_run) m_run <= 1'b1;
    if (m_run && !m_done) begin
        if (m_win == TICK_WIN - 25'd1) m_done <= 1'b1;
        else m_win <= m_win + 25'd1;
    end
end
always @(posedge clk54) begin
    md54_s <= {md54_s[0], m_done};
    if (m_run && !md54_s[1]) clk54_ticks <= clk54_ticks + 25'd1;
end

// ==================== A5: clock bypass mux -> dclk domain ====================
reg clk_half = 1'b0;
always @(posedge clk) clk_half <= ~clk_half;

wire dclk = (clk_sel == 2'd0) ? clk :
            (clk_sel == 2'd1) ? clk54 : clk_half;

// auto-hold the domain in reset for 255 clks after a clock-source switch
reg [7:0] dsw_cnt  = 8'd0;
reg       dsw_hold = 1'b0;
always @(posedge clk) begin
    if (wr_ok && (cmd_addr == 8'h04)) begin
        dsw_hold <= 1'b1; dsw_cnt <= 8'd0;
    end else if (dsw_hold) begin
        if (dsw_cnt == 8'hFF) dsw_hold <= 1'b0;
        else                  dsw_cnt <= dsw_cnt + 8'd1;
    end
end
wire drst_raw_n = rst_n & ~dom_rst[0] & ~dsw_hold;
reg [1:0] drst_s = 2'b00;
always @(posedge dclk or negedge drst_raw_n)
    if (!drst_raw_n) drst_s <= 2'b00;
    else             drst_s <= {drst_s[0], 1'b1};
wire drst_n = drst_s[1];

// ==================== A12/A15: clock gate + single-step =======================
reg [2:0] cg;   // bit0 gate_en (def 1), bit1 step_mode, bit2 override
always @(posedge clk or negedge rst_n)
    if (!rst_n) cg <= 3'b001;
    else if (wr_ok && (cmd_addr == 8'h05)) cg <= cmd_wdata[2:0];

wire step_wr = wr_ok && (cmd_addr == 8'h02) && cmd_wdata[1];
reg step_tgl = 1'b0;
always @(posedge clk) if (step_wr) step_tgl <= ~step_tgl;
reg [2:0] st_s = 3'b000;
always @(posedge dclk) st_s <= {st_s[1:0], step_tgl};
wire step_d  = st_s[2] ^ st_s[1];
wire dclk_en = cg[2] ? 1'b1 : (cg[1] ? step_d : cg[0]);

// ==================== A8: fault injection ===================================
reg [3:0] fi;
always @(posedge clk or negedge rst_n)
    if (!rst_n) fi <= 4'd0;
    else if (wr_ok && (cmd_addr == 8'h06)) fi <= cmd_wdata[3:0];
reg [7:0] fi_addr;
always @(posedge clk or negedge rst_n)
    if (!rst_n) fi_addr <= 8'd0;
    else if (wr_ok && (cmd_addr == 8'h07)) fi_addr <= cmd_wdata[7:0];

// ==================== A9+B2: golden unit + shadow checker ===================
wire        g_busy, g_done;
wire [15:0] g_cnt, g_acc, g_shf;
wire [31:0] g_digest;
golden_ref #(.CYCLES(GOLD_CYCLES)) u_gold (
    .clk(dclk), .clk_en(dclk_en), .rst_n(drst_n),
    .fi_xor(fi[0] ? 16'h00FF : 16'd0),
    .busy(g_busy), .done(g_done),
    .cnt(g_cnt), .acc(g_acc), .shf(g_shf), .digest(g_digest));

// shadow model: clean copy of the golden sequence in the same domain
function [15:0] galu;
    input [15:0] a;
    input [15:0] c;
    begin
        case (c[1:0])
            2'd0: galu = a + c;
            2'd1: galu = a ^ c;
            2'd2: galu = {a[14:0], a[15]} + {8'd0, c[7:0]};
            default: galu = a - c;
        endcase
    end
endfunction

reg [15:0] sh_acc = 16'h0001, sh_cnt = 16'd0;
reg        sh_busy = 1'b1;
always @(posedge dclk or negedge drst_n) begin
    if (!drst_n) begin
        sh_acc <= 16'h0001; sh_cnt <= 16'd0; sh_busy <= 1'b1;
    end else if (dclk_en) begin
        if (sh_busy) begin
            sh_acc <= galu(sh_acc, sh_cnt);
            if (sh_cnt == GOLD_CYCLES - 16'd1) sh_busy <= 1'b0;
            else sh_cnt <= sh_cnt + 16'd1;
        end
    end
end

// B2 first-mismatch latch + trigger strobe: the DUT acc must equal the clean
// shadow acc every active beat; divergence means fault/silicon, not RTL.
reg        first_err = 1'b0, trig_sticky = 1'b0, trig_pulse = 1'b0;
reg [15:0] mis_cnt = 16'd0, err_cyc = 16'd0;
reg [15:0] err_exp = 16'd0, err_got = 16'd0;
always @(posedge dclk or negedge drst_n) begin
    if (!drst_n) begin
        first_err <= 1'b0; trig_sticky <= 1'b0; trig_pulse <= 1'b0;
        mis_cnt <= 16'd0; err_cyc <= 16'd0;
        err_exp <= 16'd0; err_got <= 16'd0;
    end else if (dclk_en) begin
        trig_pulse <= 1'b0;
        if (sh_busy && (g_acc != sh_acc)) begin
            mis_cnt     <= mis_cnt + 16'd1;
            trig_pulse  <= 1'b1;
            trig_sticky <= 1'b1;
            if (!first_err) begin
                first_err <= 1'b1;
                err_cyc   <= sh_cnt;
                err_exp   <= sh_acc;
                err_got   <= g_acc;
            end
        end
    end
end

wire digest_match = g_done && (g_digest == GOLD_DIGEST);

// ==================== A10: bypassable pipeline ===============================
wire [15:0] p_y0, p_y1, p_y2;
wire        p_valid;
reg  [2:0]  p_byp;
always @(posedge clk or negedge rst_n)
    if (!rst_n) p_byp <= 3'd0;
    else if (wr_ok && (cmd_addr == 8'h0E)) p_byp <= cmd_wdata[2:0];
wire p_kick_w = wr_ok && (cmd_addr == 8'h0D) && cmd_wdata[16];
reg [15:0] p_din;
// p_din loads on the same edge the kick would fire -> the pipe would sample
// the PREVIOUS seed.  Delay kick one clk so p_din_fi is settled.
reg        p_kick = 1'b0;
always @(posedge clk or negedge rst_n)
    if (!rst_n) p_kick <= 1'b0;
    else        p_kick <= p_kick_w;
always @(posedge clk) if (p_kick_w) p_din <= cmd_wdata[15:0];
wire [15:0] p_din_fi = p_din ^ (fi[3] ? 16'h0001 : 16'd0);
dbg_pipe3 u_pipe (
    .clk(dclk), .clk_en(dclk_en), .rst_n(drst_n),
    .kick(p_kick), .din(p_din_fi), .bypass(p_byp),
    .y0(p_y0), .y1(p_y1), .y2(p_y2), .valid(p_valid));

// ==================== A2+A14: MBIST with host RAM port ========================
wire        mb_busy, mb_done, mb_fail;
wire [7:0]  mb_fa, mb_fe, mb_fg;
wire [3:0]  mb_fp, mb_ph;
wire [7:0]  mb_hq;
wire        mb_start = wr_ok && (cmd_addr == 8'h08) && cmd_wdata[0];
// auto-run once after boot
reg mb_auto = 1'b0;
always @(posedge clk or negedge rst_n)
    if (!rst_n) mb_auto <= 1'b0;
    else if (!mb_busy && !mb_done) mb_auto <= 1'b1;
wire mb_go = mb_start || (mb_auto && !mb_busy && !mb_done);

wire        mb_hwe = wr_ok && (cmd_addr == 8'h0F) && cmd_wdata[16];
wire        mb_hre = wr_ok && (cmd_addr == 8'h0F) && cmd_wdata[17];
wire [7:0]  mb_ha  = cmd_wdata[15:8];
wire [7:0]  mb_hw  = cmd_wdata[7:0];
reg         mb_re_r = 1'b0;
always @(posedge clk or negedge rst_n)
    if (!rst_n) mb_re_r <= 1'b0;
    else        mb_re_r <= mb_hre;

mem_bist #(.DEPTH(256), .AW(8)) u_mbist (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n & ~dom_rst[1]),
    .start(mb_go),
    .busy(mb_busy), .done(mb_done), .fail(mb_fail),
    .fail_addr(mb_fa), .fail_exp(mb_fe), .fail_got(mb_fg),
    .fail_phase(mb_fp), .phase(mb_ph),
    .fi_en(fi[1]), .fi_addr(fi_addr),
    .h_we(mb_hwe), .h_waddr(mb_ha), .h_wdata(mb_hw),
    .h_re(mb_re_r), .h_raddr(mb_ha), .h_q(mb_hq));

// ==================== A13: ring oscillator + freq counter ====================
wire ro_raw;
ring_osc #(.STAGES(15)) u_ro (.en(rst_n), .ro(ro_raw));
// divide ro by 64 with a ripple counter clocked by ro itself
reg [5:0] ro_div = 6'd0;
always @(posedge ro_raw) ro_div <= ro_div + 6'd1;
// count ro/64 rising edges over the TICK_WIN window (2FF sync + edge detect)
reg [1:0]  rod_s = 2'b00;
reg        rod_d = 1'b0;
reg [23:0] ro_edges = 24'd0;
always @(posedge clk) begin
    rod_s <= {rod_s[0], ro_div[5]};
    rod_d <= rod_s[1];
    if (m_run && !m_done && (rod_s[1] & ~rod_d) && (ro_edges != 24'hFFFFFF))
        ro_edges <= ro_edges + 24'd1;
end
wire ro_alive = (ro_edges != 24'd0) && (ro_edges != 24'hFFFFFF);

// ==================== A17: UART TX loopback ==================================
wire [7:0] lb_data;
wire       lb_valid, lb_ferr;
reg        lb_ack = 1'b0;
uart_rx #(.CLK_FRE(27), .BAUD_RATE(115200)) u_rx_lb (
    .clk(clk), .rst_n(rst_n & ~dom_rst[3]), .clk_en(1'b1),
    .rx_pin(uart_tx), .rx_data(lb_data),
    .rx_valid(lb_valid), .rx_ack(lb_ack), .framing_err(lb_ferr));
reg [7:0] lb_count = 8'd0, lb_last = 8'd0;
reg       lb_err = 1'b0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lb_count <= 8'd0; lb_last <= 8'd0; lb_err <= 1'b0;
        lb_ack   <= 1'b0;
    end else begin
        lb_ack <= lb_valid && !lb_ack;   // auto-ack each received byte
        if (lb_valid && !lb_ack) begin
            lb_count <= lb_count + 8'd1;
            lb_last  <= lb_data;
            if (lb_ferr) lb_err <= 1'b1;
        end
    end
end
wire [7:0] lb_count_w = lb_count;

// ==================== A1: scan chain + boot self-check ======================
reg        rg_se = 1'b0, rg_si = 1'b0;
wire       w9      = wr_ok && (cmd_addr == 8'h09);
wire       rg_cap  = w9 && cmd_wdata[2];
wire       rg_step = w9 && cmd_wdata[3];
// during a W9 write the chain must see THAT write's se/si (the registered
// copies only update at the same edge the step pulse fires -> off-by-one)
wire       sc_se_r = w9 ? cmd_wdata[0] : rg_se;
wire       sc_si_r = w9 ? cmd_wdata[1] : rg_si;
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin rg_se <= 1'b0; rg_si <= 1'b0; end
    else if (w9) begin
        rg_se <= cmd_wdata[0]; rg_si <= cmd_wdata[1];
    end

wire        tap_cap, tap_shift, tap_si, tap_sel, tap_tdo;
wire [3:0]  tap_state, tap_ir;
reg  [15:0] tap_tck_cnt = 16'd0;
wire        tap_tck = wr_ok && (cmd_addr == 8'h0A) && cmd_wdata[2];
always @(posedge clk) if (tap_tck) tap_tck_cnt <= tap_tck_cnt + 16'd1;

// boot self-check: capture known pattern, shift it out, count ones == 32
localparam [63:0] SCAN_PATT = 64'hA5A5_3C3C_F0F0_0F0F;
reg [2:0] bs_st = 3'd0;
reg [6:0] bs_i    = 7'd0;
reg [6:0] bs_ones = 7'd0;
reg       scan_boot_ok = 1'b0, scan_boot_done = 1'b0;
wire      bs_act = (bs_st != 3'd0) && (bs_st != 3'd4);

wire [63:0] status_vec = {por_count, por_cycles, pll_lock_cycles,
                          clk54_ticks[15:0], lb_count_w};

wire sc_so;
wire sc_se   = bs_act | tap_sel | sc_se_r;
wire sc_si   = bs_act ? 1'b0 : (tap_sel ? tap_si : sc_si_r);
wire sc_step = (bs_st == 3'd2) | rg_step | tap_shift;
wire sc_cap  = (bs_st == 3'd1) | rg_cap | tap_cap;
wire [63:0] sc_capi = bs_act ? SCAN_PATT : status_vec;
wire [63:0] sc_chain;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bs_st <= 3'd0; bs_i <= 7'd0; bs_ones <= 7'd0;
        scan_boot_ok <= 1'b0; scan_boot_done <= 1'b0;
    end else begin
        case (bs_st)
            3'd0: bs_st <= 3'd1;
            3'd1: begin bs_st <= 3'd2; bs_i <= 7'd0; bs_ones <= 7'd0; end
            3'd2: begin
                if (sc_so) bs_ones <= bs_ones + 7'd1;
                if (bs_i == 7'd63) bs_st <= 3'd3;
                else               bs_i <= bs_i + 7'd1;
            end
            3'd3: begin
                scan_boot_done <= 1'b1;
                scan_boot_ok   <= (bs_ones == 7'd32);
                bs_st <= 3'd4;
            end
            default: bs_st <= 3'd4;
        endcase
    end
end

dft_scan_chain #(.LEN(64)) u_scan (
    .clk(clk), .rst_n(rst_n & ~dom_rst[3]),
    .se(sc_se), .si(sc_si), .step(sc_step), .cap(sc_cap),
    .cap_i(sc_capi), .fi_stuck(fi[2]),
    .so(sc_so), .chain_o(sc_chain));

// ==================== A3: mini JTAG TAP =====================================
tap_mini u_tap (
    .clk(clk), .rst_n(rst_n & ~dom_rst[3]),
    .tck(tap_tck), .tms(cmd_wdata[0]), .tdi(cmd_wdata[1]),
    .sample_i(status_vec),
    .scan_so(sc_so), .scan_cap(tap_cap), .scan_shift(tap_shift),
    .scan_si(tap_si), .sel_chain(tap_sel),
    .tdo(tap_tdo), .state(tap_state), .ir(tap_ir));

// ==================== A11: mini-ILA on the debug bus =========================
wire       ila_busy, ila_done, ila_fired;
wire [9:0] ila_tptr_w;
wire [7:0] ila_rq;
wire       ila_cwe = wr_ok && (cmd_addr == 8'h0B);
wire       ila_arm = ila_cwe && cmd_wdata[18];
reg  [9:0] ila_raddr = 10'd0;
reg        ila_re = 1'b0;
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin ila_raddr <= 10'd0; ila_re <= 1'b0; end
    else begin
        ila_re <= 1'b0;
        if (wr_ok && (cmd_addr == 8'h0C)) begin
            ila_raddr <= cmd_wdata[9:0];
            ila_re    <= 1'b1;
        end
    end

reg [7:0] dbg_r;   // forward decl; driven by probe mux below
ila_core #(.AW(10)) u_ila (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n & ~dom_rst[2]),
    .probe(dbg_r),
    .cfg_we(ila_cwe && !cmd_wdata[18]), .cfg_addr(cmd_wdata[1:0]),
    .cfg_data(cmd_wdata[17:2]),
    .arm(ila_arm),
    .busy(ila_busy), .done(ila_done), .fired(ila_fired),
    .trig_ptr(ila_tptr_w),
    .rd_en(ila_re), .rd_addr(ila_raddr), .rd_q(ila_rq));

// ==================== T5: UART command parser ================================
wire [7:0] rx_data;
wire       rx_valid, rx_ferr;
reg        rx_ack = 1'b0;
uart_rx #(.CLK_FRE(27), .BAUD_RATE(115200)) u_rx (
    .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
    .rx_pin(uart_rx_pin), .rx_data(rx_data),
    .rx_valid(rx_valid), .rx_ack(rx_ack), .framing_err(rx_ferr));

reg [2:0] cmd_st   = 3'd0;
reg [2:0] cmd_wcnt = 3'd0;
reg [3:0] probe_sel = 4'd0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cmd_st <= 3'd0; cmd_addr <= 8'd0; cmd_wdata <= 32'd0;
        cmd_wcnt <= 3'd0; cmd_we <= 1'b0; cmd_re <= 1'b0; cmd_rep <= 1'b0;
        rx_ack <= 1'b0; probe_sel <= 4'd0;
    end else begin
        rx_ack <= 1'b0; cmd_we <= 1'b0; cmd_re <= 1'b0; cmd_rep <= 1'b0;
        if (rx_valid && !rx_ack) begin
            rx_ack <= 1'b1;
            case (cmd_st)
                3'd0: case (rx_data)
                        8'h57: cmd_st <= 3'd1;          // 'W'
                        8'h52: cmd_st <= 3'd6;          // 'R'
                        8'h50: cmd_st <= 3'd7;          // 'P'
                        8'h54: cmd_rep <= 1'b1;         // 'T'
                        default: ;
                      endcase
                3'd1: begin cmd_addr <= rx_data; cmd_wcnt <= 3'd0;
                            cmd_st <= 3'd2; end
                3'd2: begin cmd_wdata <= {rx_data, cmd_wdata[31:8]};
                            if (cmd_wcnt == 3'd3) begin
                                cmd_we <= 1'b1; cmd_st <= 3'd0;
                            end else cmd_wcnt <= cmd_wcnt + 3'd1;
                      end
                3'd6: begin cmd_addr <= rx_data; cmd_re <= 1'b1;
                            cmd_st <= 3'd0; end
                3'd7: begin probe_sel <= rx_data[3:0]; cmd_st <= 3'd0; end
                default: cmd_st <= 3'd0;
            endcase
        end
    end
end

// RW scratch
reg [31:0] scratch = 32'd0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) scratch <= 32'd0;
    else if (wr_ok && (cmd_addr == 8'd0)) scratch <= cmd_wdata;
end

// ------------------------------ regmap -------------------------------------
function [31:0] reg_read;
    input [7:0] a;
    begin
        case (a)
            8'h00: reg_read = scratch;
            8'h01: reg_read = {27'd0, por_bit};
            8'h03: reg_read = {28'd0, dom_rst};
            8'h04: reg_read = {30'd0, clk_sel};
            8'h05: reg_read = {29'd0, cg};
            8'h06: reg_read = {28'd0, fi};
            8'h07: reg_read = {24'd0, fi_addr};
            8'h09: reg_read = {29'd0, scan_boot_ok, tap_sel, sc_so};
            8'h0A: reg_read = {26'd0, tap_tdo, tap_state, 1'b0};
            8'h0C: reg_read = {24'd0, ila_rq};
            8'h0D: reg_read = {16'd0, p_din};
            8'h0E: reg_read = {29'd0, p_byp};
            8'h0F: reg_read = {24'd0, mb_hq};
            // status block (T-report range)
            8'h10: reg_read = {por_count, rst_glitch, por_bit_eff,
                               2'd0, por_cycles};
            8'h11: reg_read = {pll_lock_seen, pll_lock, pll_lock_cycles,
                               test_lock, clk_sel, dom_rst, 7'd0};
            8'h12: reg_read = {6'd0, m_done, clk54_ticks};
            8'h13: reg_read = {7'd0, ro_alive, ro_edges};
            8'h14: reg_read = g_digest;
            8'h15: reg_read = {g_done, digest_match, g_busy, first_err,
                               trig_sticky, 11'd0, mis_cnt};
            8'h16: reg_read = {err_exp, err_got};
            8'h17: reg_read = {err_cyc, g_cnt};
            8'h18: reg_read = {mb_busy, mb_done, mb_fail, 1'd0,
                               mb_fp, mb_ph, mb_fa};
            8'h19: reg_read = {mb_fe, mb_fg, 8'd0, mb_hq};
            8'h1A: reg_read = {scan_boot_ok, scan_boot_done, tap_sel, sc_so,
                               tap_tdo, tap_state, tap_ir,
                               tap_tck_cnt[15:0]};
            8'h1B: reg_read = {p_y0, p_y1};
            8'h1C: reg_read = {p_y2, 12'd0, p_valid, p_byp};
            8'h1D: reg_read = {ila_busy, ila_done, ila_fired, 5'd0,
                               14'd0, ila_tptr_w};
            8'h1E: reg_read = {probe_sel, lb_err, 2'd0, lb_count,
                               lb_last, 5'd0, cg};
            8'h1F: reg_read = 32'h5441_5045;          // "TAPE"
            default: reg_read = 32'hDEAD_0000 | {24'd0, a};
        endcase
    end
endfunction

// ==================== UART TX reply engine (as top_hwverify) =================
reg [7:0] rq [0:63];
reg [5:0] rq_w = 6'd0, rq_r = 6'd0;
reg [6:0] rq_n = 7'd0;
reg       tx_valid = 1'b0;
reg [7:0] tx_dat = 8'd0;
wire      tx_ready, tx_busy;
uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) u_tx (
    .clk(clk), .rst_n(rst_n),
    .tx_data(tx_dat), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(uart_tx), .tx_busy(tx_busy));

function [7:0] hexn;
    input [3:0] v; hexn = (v < 10) ? (8'h30 + v) : (8'h41 + v - 10);
endfunction

reg       f_on = 1'b0;
reg [1:0] f_kind = 2'd0;          // 1=R, 2=T
reg [7:0] f_i = 8'd0;
reg [31:0] f_word = 32'd0;
reg [4:0] f_reg = 5'd0;
reg [7:0] fmt_byte;

always @(*) begin
    fmt_byte = 8'h20;
    if (f_kind == 2'd1) begin
        case (f_i[3:0])
            4'd0:  fmt_byte = "R";
            4'd1:  fmt_byte = "=";
            4'd2:  fmt_byte = hexn(f_word[31:28]);
            4'd3:  fmt_byte = hexn(f_word[27:24]);
            4'd4:  fmt_byte = hexn(f_word[23:20]);
            4'd5:  fmt_byte = hexn(f_word[19:16]);
            4'd6:  fmt_byte = hexn(f_word[15:12]);
            4'd7:  fmt_byte = hexn(f_word[11:8]);
            4'd8:  fmt_byte = hexn(f_word[7:4]);
            4'd9:  fmt_byte = hexn(f_word[3:0]);
            4'd10: fmt_byte = 8'h0d;
            default: fmt_byte = 8'h0a;
        endcase
    end else begin
        // 'T' report: regs 0x10..0x1F as "Rn=XXXXXXXX\r\n"
        case (f_i[3:0])
            4'd0:  fmt_byte = "R";
            4'd1:  fmt_byte = hexn({3'b0, f_reg[3:0]});
            4'd2:  fmt_byte = "=";
            4'd3:  fmt_byte = hexn(f_word[31:28]);
            4'd4:  fmt_byte = hexn(f_word[27:24]);
            4'd5:  fmt_byte = hexn(f_word[23:20]);
            4'd6:  fmt_byte = hexn(f_word[19:16]);
            4'd7:  fmt_byte = hexn(f_word[15:12]);
            4'd8:  fmt_byte = hexn(f_word[11:8]);
            4'd9:  fmt_byte = hexn(f_word[7:4]);
            4'd10: fmt_byte = hexn(f_word[3:0]);
            4'd11: fmt_byte = 8'h0d;
            default: fmt_byte = 8'h0a;
        endcase
    end
end

wire fmt_done = (f_kind == 2'd1 && f_i[3:0] == 4'd11) ||
                (f_kind == 2'd2 && f_i[3:0] == 4'd12 && f_reg == 5'd15);
wire rq_free = (rq_n <= 7'd60);
wire pop = (!tx_valid && !tx_busy && rq_n != 7'd0);
wire push = f_on && rq_free;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rq_w <= 6'd0; rq_r <= 6'd0; rq_n <= 7'd0;
        tx_valid <= 1'b0; tx_dat <= 8'd0;
        f_on <= 1'b0; f_kind <= 2'd0; f_i <= 8'd0; f_word <= 32'd0;
        f_reg <= 5'd0;
    end else begin
        if (cmd_re && !f_on) begin
            f_on <= 1'b1; f_kind <= 2'd1; f_i <= 8'd0;
            f_word <= reg_read(cmd_addr); f_reg <= 5'd0;
        end else if (cmd_rep && !f_on) begin
            f_on <= 1'b1; f_kind <= 2'd2; f_i <= 8'd0;
            f_word <= reg_read(8'h10); f_reg <= 5'd0;
        end
        if (push) begin
            rq[rq_w] <= fmt_byte;
            rq_w <= rq_w + 6'd1;
            if (f_i[3:0] == 4'd12 && f_kind == 2'd2) begin
                f_i <= 8'd0;
                f_reg <= f_reg + 5'd1;
                f_word <= reg_read(8'h10 + {3'd0, f_reg} + 8'd1);
            end else begin
                f_i <= f_i + 8'd1;
            end
            if (fmt_done) f_on <= 1'b0;
        end
        if (tx_valid && tx_busy) begin
            tx_valid <= 1'b0;
        end else if (pop) begin
            tx_valid <= 1'b1;
            tx_dat <= rq[rq_r];
            rq_r <= rq_r + 6'd1;
        end
        case ({push, pop})
            2'b10: rq_n <= rq_n + 7'd1;
            2'b01: rq_n <= rq_n - 7'd1;
            default: rq_n <= rq_n;
        endcase
    end
end

// ==================== A4: debug mux (dbg7 = trigger, always) =================
reg hb = 1'b0;
reg [22:0] hb_c = 23'd0;
always @(posedge clk) begin
    hb_c <= hb_c + 23'd1;
    if (hb_c == 23'd0) hb <= ~hb;
end

// divided clocks for LA observation
reg [4:0] c27_c = 5'd0;  reg clk27_div = 1'b0;   // 27/64  ~ 422 kHz
reg [4:0] c54_c = 5'd0;  reg clk54_div = 1'b0;   // 54/64  ~ 844 kHz
reg [4:0] cdc_c = 5'd0;  reg dclk_div  = 1'b0;   // dclk/64
always @(posedge clk)   begin c27_c <= c27_c + 5'd1; if (c27_c == 5'd0) clk27_div <= ~clk27_div; end
always @(posedge clk54) begin c54_c <= c54_c + 5'd1; if (c54_c == 5'd0) clk54_div <= ~clk54_div; end
always @(posedge dclk)  begin cdc_c <= cdc_c + 5'd1; if (cdc_c == 5'd0) dclk_div  <= ~dclk_div;  end

wire osc_clk;
OSC #(.FREQ_DIV(100), .DEVICE("GW2A-18")) u_osc (.OSCOUT(osc_clk));

wire trig_out = trig_sticky | trig_pulse | rst_glitch;

reg [6:0] page_r;
always @(*) begin
    case (probe_sel)
        // boot / reset / pll view
        4'd0: page_r = {rst_n, pll_lock, mb_busy, g_done,
                        sc_so, tap_tdo, hb};
        // clocks view (B3/A6/A13)
        4'd1: page_r = {clk27_div, clk54_div, dclk_div, ro_div[5],
                        osc_clk, clk_sel[0], hb};
        // scan + TAP wires
        4'd2: page_r = {sc_se, sc_si, sc_so, tap_tck,
                        cmd_wdata[0], cmd_wdata[1], tap_tdo};
        // engines
        4'd3: page_r = {mb_busy, mb_done, mb_fail, g_busy,
                        g_done, digest_match, ila_fired};
        // bus activity
        4'd4: page_r = {rx_valid, cmd_we, tx_busy, uart_tx,
                        lb_valid, lb_err, step_d};
        // sticky status / alarms
        default: page_r = {scan_boot_ok, first_err, rst_glitch,
                           test_lock, ro_alive, m_done, hb};
    endcase
end
always @(*) dbg_r = {trig_out, page_r};
assign {dbg7, dbg6, dbg5, dbg4, dbg3, dbg2, dbg1, dbg0} = dbg_r;

// ==================== aggregate status =======================================
wire hw_done = g_done && mb_done && pll_lock_seen && scan_boot_done && m_done;
wire hw_pass = digest_match && !mb_fail && pll_lock_seen && scan_boot_ok &&
               !first_err && ro_alive;
assign status_pass = hw_done && hw_pass;
assign status_fail = hw_done && !hw_pass;

endmodule
