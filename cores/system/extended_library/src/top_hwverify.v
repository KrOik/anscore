// ============================================================================
// top_hwverify -- wave2 board-level timing/hardware verification top.
//
// Exercises eight board-visible behaviours on real silicon:
//   T0 reset timing & synchronisation   (POR length, 2FF sync, glitch watch)
//   T1 PLL lock + margin                (rPLL 27->54 MHz, lock latency, CSC
//                                        selftest re-run in the 54 MHz domain)
//   T2 CDC / metastability              (OSC ~2.5 MHz async domain, req/ack
//                                        handshake xfer check, parallel 1FF
//                                        disagreement counter, sync latency)
//   T3 datapath connectivity/throughput (st_isp_csc at full rate; cycle count
//                                        vs sim golden 2121)
//   T4 boundary / exception             (wdt_win early/late/timeout events,
//                                        tmr_voter single-lane corruption)
//   T5 control regs / bus               (UART RX command parser, R/W regmap,
//                                        scratch readback)
//   T6 general control / low-speed I/F  (pwm_gen duty on probe pin, qei_dec
//                                        quadrature loopback, step_drv pulses)
//   T7 physical timing margin           (CSC selftest at 54 MHz = 2x margin)
//
// UART command protocol (115200 8N1, rx on T13):
//   'W' a d0 d1 d2 d3   -> regs[a] = {d0,d1,d2,d3} little-endian data
//   'R' a               -> "R=XXXXXXXX\r\n"
//   'P' s               -> probe mux select
//   'T'                 -> emit 16-reg result report ("Rn=XXXXXXXX\r\n" x16)
//
// dbg[7:0] LA probe bus (A11 B11 N6 D11 N9 N7 L9 N8), muxed by probe_sel.
// ============================================================================
module top_hwverify #(
    parameter [24:0] TICK_WIN = 25'd27_000_000,  // clk54-tick window (1 s)
    parameter [4:0]  POR_BIT  = 5'd12            // reset_count[POR_BIT]=rst_n
) (
    input  wire       clk,            // H11, 27 MHz
    input  wire       uart_rx_pin,    // T13
    output wire       uart_tx,        // M11
    output wire       status_pass,    // T9
    output wire       status_fail,    // P9
    output wire       dbg7,           // A11 \
    output wire       dbg6,           // B11  |
    output wire       dbg5,           // N6   | LA probe bus
    output wire       dbg4,           // D11  |
    output wire       dbg3,           // N9   |
    output wire       dbg2,           // N7   |
    output wire       dbg1,           // L9   |
    output wire       dbg0            // N8  /
);

// forward declarations (referenced before their generating sections)
reg        cmd_we;
reg        cmd_re;
reg        cmd_rep;
reg [7:0]  cmd_addr;
reg [31:0] cmd_wdata;
reg        c_ack;

// ---------------- power-on reset ---------------------------------------------
reg [25:0] reset_count = 26'd0;
wire rst_n = reset_count[POR_BIT];
always @(posedge clk) if (!rst_n) reset_count <= reset_count + 26'd1;

// T0: reset synchronisation chain + re-assertion watchdog
reg rst_s1 = 1'b0, rst_s2 = 1'b0;
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin rst_s1 <= 1'b0; rst_s2 <= 1'b0; end
    else      begin rst_s1 <= 1'b1; rst_s2 <= rst_s1; end

reg [15:0] por_cycles = 16'd0;   // counts clks until rst_n releases (~4095)
always @(posedge clk)
    if (!rst_n) por_cycles <= por_cycles + 16'd1;

reg rst_ever = 1'b0, rst_glitch = 1'b0;
always @(posedge clk) begin
    if (rst_s2) rst_ever <= 1'b1;
    if (rst_ever && !rst_s1) rst_glitch <= 1'b1;   // must never fire
end

// ---------------- T1/T7: rPLL 27 -> 54 MHz -----------------------------------
wire clk54, pll_lock;
rPLL #(
    .FCLKIN("27.0"),
    .IDIV_SEL(0),     // PFD = 27 MHz
    .FBDIV_SEL(1),    // CLKOUT = 54 MHz
    .ODIV_SEL(16)     // VCO = 864 MHz
) u_pll (
    .CLKOUT(clk54), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
    .LOCK(pll_lock), .CLKIN(clk), .CLKFB(1'b0), .FBDSEL(6'b0),
    .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0),
    .FDLY(4'b0), .RESET(~rst_n), .RESET_P(1'b0)  // hold PLL in POR so the
);                                              // lock latency is observable

// lock latency on the 27 MHz clock
reg [15:0] pll_lock_cycles = 16'd0;
reg        pll_lock_seen   = 1'b0;
always @(posedge clk)
    if (rst_n && !pll_lock_seen) begin
        if (!pll_lock) pll_lock_cycles <= pll_lock_cycles + 16'd1;
        else           pll_lock_seen   <= 1'b1;
    end

// frequency check: count clk54 edges during a 27M-clk (1 s) window.
// m_done is synchronised into the clk54 domain; the tick counter stops and
// holds a quiesced value, so the clk domain may read it safely.
reg        m_run  = 1'b0;
reg [24:0] m_win  = 25'd0;
reg        m_done = 1'b0;
reg [24:0] clk54_ticks = 25'd0;
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

// 54 MHz domain reset: released two clk54 edges after LOCK (comm pattern)
reg [1:0] rst54_s = 2'b00;
always @(posedge clk54 or negedge pll_lock)
    if (!pll_lock) rst54_s <= 2'b00;
    else           rst54_s <= {rst54_s[0], 1'b1};
wire rst54_n = rst54_s[1] & rst_n;

// CSC selftest re-run at 54 MHz (physical timing margin)
wire        csc54_done, csc54_pass;
wire [31:0] csc54_digest;
wire [15:0] csc54_cyc;
reg  csc54_start = 1'b0;
always @(posedge clk54 or negedge rst54_n)
    if (!rst54_n) csc54_start <= 1'b0;
    else          csc54_start <= 1'b1;
st_isp_csc u_csc54 (
    .clk(clk54), .clk_en(1'b1), .rst_n(rst54_n),
    .start(csc54_start),
    .done(csc54_done), .pass(csc54_pass),
    .digest(csc54_digest), .cycles(csc54_cyc));

// second rPLL: 27 MHz -> 33.75 MHz (PFD 6.75 MHz, x5, VCO 540 MHz) --
// brackets the real Fmax between the passing 27 MHz run and the failing
// intermediate accepted margin point between the 27 MHz and 54 MHz runs
wire clk33, pll33_lock;
rPLL #(
    .FCLKIN("27.0"),
    .IDIV_SEL(3),     // PFD = 6.75 MHz
    .FBDIV_SEL(4),    // CLKOUT = 27 * 5 / 4 = 33.75 MHz
    .ODIV_SEL(16)     // VCO  = 33.75 * 16 = 540 MHz
) u_pll33 (
    .CLKOUT(clk33), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
    .LOCK(pll33_lock), .CLKIN(clk), .CLKFB(1'b0), .FBDSEL(6'b0),
    .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0),
    .FDLY(4'b0), .RESET(~rst_n), .RESET_P(1'b0)
);
reg [1:0] rst33_s = 2'b00;
always @(posedge clk33 or negedge pll33_lock)
    if (!pll33_lock) rst33_s <= 2'b00;
    else             rst33_s <= {rst33_s[0], 1'b1};
wire rst33_n = rst33_s[1] & rst_n;

wire        csc33_done, csc33_pass;
wire [31:0] csc33_digest;
wire [15:0] csc33_cyc;
reg  csc33_start = 1'b0;
always @(posedge clk33 or negedge rst33_n)
    if (!rst33_n) csc33_start <= 1'b0;
    else          csc33_start <= 1'b1;
st_isp_csc u_csc33 (
    .clk(clk33), .clk_en(1'b1), .rst_n(rst33_n),
    .start(csc33_start),
    .done(csc33_done), .pass(csc33_pass),
    .digest(csc33_digest), .cycles(csc33_cyc));

// ---------------- T2: CDC + metastability ------------------------------------
// on-chip oscillator: genuinely asynchronous domain (~2.5 MHz)
wire osc_clk;
OSC #(.FREQ_DIV(100), .DEVICE("GW2A-18")) u_osc (.OSCOUT(osc_clk));

// async-domain producer: increments on each completed handshake.
// data leads req by one osc period so the bus is quiescent before the
// request edge leaves this domain (multi-bit CDC needs settle time > the
// consumer's 2FF sync latency).
reg [7:0] o_cnt   = 8'd0;
reg       o_req   = 1'b0;
reg       o_pend  = 1'b0;
reg [1:0] o_ack_s = 2'b00;
always @(posedge osc_clk) begin
    o_ack_s <= {o_ack_s[0], c_ack};
    if (o_pend) begin
        o_pend <= 1'b0;
        o_req  <= ~o_req;
    end else if (o_ack_s[1] == o_req) begin
        o_cnt  <= o_cnt + 8'd1;
        o_pend <= 1'b1;
    end
end

// clk domain consumer: 2FF req sync, quiesced-data capture, toggle ack
reg [1:0]  c_req_s = 2'b00;
reg [7:0]  c_exp   = 8'd0;
reg [15:0] cdc_xfers = 16'd0;
reg [15:0] cdc_errs  = 16'd0;
reg [7:0]  cdc_lat   = 8'd0;
reg [7:0]  cdc_lat_c = 8'd0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        c_req_s <= 2'b00; c_exp <= 8'd0; c_ack <= 1'b0;
        cdc_xfers <= 16'd0; cdc_errs <= 16'd0;
        cdc_lat <= 8'd0; cdc_lat_c <= 8'd0;
    end else begin
        c_req_s <= {c_req_s[0], o_req};
        if (c_req_s[1] != c_ack) begin
            c_ack <= c_req_s[1];
            // first transfer only establishes the sequence (the OSC domain
            // free-runs during POR); compare all later transfers
            if (cdc_xfers != 16'd0 && o_cnt !== c_exp)
                cdc_errs <= cdc_errs + 16'd1;
            cdc_xfers <= cdc_xfers + 16'd1;
            c_exp <= o_cnt + 8'd1;
            cdc_lat <= cdc_lat_c;
            cdc_lat_c <= 8'd0;
        end else if (cdc_lat_c != 8'hFF) cdc_lat_c <= cdc_lat_c + 8'd1;
    end
end

// metastability meter: same async bit into two parallel 1FF taps;
// disagreements = resolution-time evidence. o_slow[7] toggles ~4.8 kHz.
reg [7:0]  o_slow = 8'd0;
always @(posedge osc_clk) o_slow <= o_slow + 8'd1;
wire a_sig = o_slow[7];
reg ma = 1'b0, mb = 1'b0, ma2 = 1'b0;
reg [15:0] meta_samp = 16'd0, meta_dis = 16'd0;
always @(posedge clk) begin
    ma <= a_sig; mb <= a_sig; ma2 <= ma;
    if (rst_n && meta_samp != 16'hFFFF) begin
        meta_samp <= meta_samp + 16'd1;
        if (ma !== mb) meta_dis <= meta_dis + 16'd1;
    end
end

// ---------------- T3: datapath throughput (CSC @27 MHz full rate) -------------
wire        t3_done, t3_pass;
wire [31:0] t3_digest;
wire [15:0] t3_cyc;
reg  t3_start = 1'b0;
always @(posedge clk or negedge rst_n)
    if (!rst_n) t3_start <= 1'b0;
    else        t3_start <= 1'b1;
st_isp_csc u_csc27 (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .start(t3_start),
    .done(t3_done), .pass(t3_pass),
    .digest(t3_digest), .cycles(t3_cyc));

// ---------------- T4: boundary / exception -----------------------------------
// wdt_win: provoke early-kick, timeout, then good kick; each event must count
reg [3:0] w_st  = 4'd0;
reg [7:0] w_dly = 8'd0;
reg       w_kick = 1'b0;
wire w_reset_req, w_good, w_early, w_late, w_tout;
wire [7:0] w_cg, w_ce, w_cl, w_ct;
wdt_win #(.WMIN(8'd8), .WMAX(8'd16)) u_wdt (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .en(1'b1), .kick(w_kick), .clr(w_st == 4'd0),
    .reset_req(w_reset_req),
    .ev_good(w_good), .ev_early(w_early), .ev_late(w_late), .ev_tout(w_tout),
    .cnt_good(w_cg), .cnt_early(w_ce), .cnt_late(w_cl), .cnt_tout(w_ct));
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin w_st <= 4'd0; w_dly <= 8'd0; w_kick <= 1'b0; end
    else begin
        w_kick <= 1'b0;
        w_dly <= w_dly + 8'd1;
        case (w_st)
            4'd0:  begin w_st <= 4'd1; w_dly <= 8'd0; end
            4'd1:  if (w_dly == 8'd4) begin w_kick <= 1'b1; w_st <= 4'd2; end
            4'd2:  if (w_early) w_st <= 4'd3;          // early kick seen
            4'd3:  if (w_tout) w_st <= 4'd4;           // let it expire
            4'd4:  begin w_kick <= 1'b1; w_st <= 4'd5; end // kick while expired
            4'd5:  if (w_late) begin w_st <= 4'd6; w_dly <= 8'd0; end
            4'd6:  if (w_dly == 8'd11) begin w_kick <= 1'b1; w_st <= 4'd7; end
            4'd7:  if (w_good) w_st <= 4'd8;           // in-window kick seen
            4'd8:  w_st <= 4'd15;
            default: w_st <= 4'd15;
        endcase
    end
end
wire edge_wdt_ok = (w_st == 4'd15) && (w_ce != 8'd0) && (w_ct != 8'd0) &&
                   (w_cl != 8'd0) && (w_cg != 8'd0);

// tmr_voter: corrupt lane A then B; majority must win, err_cnt must count
reg [3:0] t_st = 4'd0;
reg       t_iv = 1'b0;
reg [7:0] t_a = 8'h5A, t_b = 8'h5A, t_c = 8'h5A;  // init==arst (DFFLEGALIZE)
reg [7:0] t_y1 = 8'd0, t_y2 = 8'd0;
wire        t_ov, t_ma, t_mb, t_mc, t_err;
wire [7:0]  t_y;
wire [15:0] t_errc;
tmr_voter #(.W(8)) u_tmr (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .in_valid(t_iv), .a(t_a), .b(t_b), .c(t_c), .clr_cnt(1'b0),
    .out_valid(t_ov), .y(t_y),
    .mism_a(t_ma), .mism_b(t_mb), .mism_c(t_mc),
    .err(t_err), .err_cnt(t_errc));
reg t_done = 1'b0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        t_st <= 4'd0; t_iv <= 1'b0; t_done <= 1'b0;
        t_a <= 8'h5A; t_b <= 8'h5A; t_c <= 8'h5A;
        t_y1 <= 8'd0; t_y2 <= 8'd0;
    end else begin
        t_iv <= 1'b0;
        case (t_st)
            4'd0:  begin t_iv <= 1'b1; t_st <= 4'd1; end   // clean vote 0x5A
            4'd1:  if (t_ov) begin t_y1 <= t_y; t_a <= 8'hA5;
                                   t_iv <= 1'b1; t_st <= 4'd2; end
            4'd2:  if (t_ov) begin t_y2 <= t_y; t_b <= 8'h33;
                                   t_iv <= 1'b1; t_st <= 4'd3; end
            4'd3:  if (t_ov) t_st <= 4'd4;
            4'd4:  t_st <= 4'd5;
            4'd5:  t_done <= 1'b1;
            default: ;
        endcase
    end
end
wire edge_tmr_ok = t_done && (t_y1 == 8'h5A) && (t_y2 == 8'h5A) &&
                   (t_errc >= 16'd2);

// ---------------- T6: low-speed interfaces -----------------------------------
// pwm_gen: period 2700 (10 kHz), duty ch0 via reg addr 20 (default 0 = off)
wire [3:0] pwm_o;
wire pwm_wr = cmd_we && (cmd_addr == 8'd20);
pwm_gen #(.PERIOD_D(16'd2700), .DUTY_D(64'd0)) u_pwm (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .reg_wr(pwm_wr), .reg_addr(3'd1), .reg_data(cmd_wdata[15:0]),
    .en(1'b1), .pwm(pwm_o));

// qei_dec loopback: internal quadrature emulator -> decoder
reg [7:0] q_ph = 8'd0;
wire q_a = q_ph[5];
wire q_b = q_ph[5] ^ q_ph[4];        // B lags A by a quarter period
always @(posedge clk or negedge rst_n)
    if (!rst_n) q_ph <= 8'd0; else q_ph <= q_ph + 8'd1;
wire [31:0] q_cnt;
wire        q_dir, q_step;
qei_dec u_qei (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .qa(q_a), .qb(q_b), .qidx(1'b0), .idx_rst(1'b0),
    .count(q_cnt), .dir(q_dir), .step_v(q_step),
    .idx_latch(), .idx_evt());

// step_drv: regs 21=interval,22=count,23=go
wire s_step, s_dir, s_busy, s_done;
wire [15:0] s_pos, s_int;
wire s_wr = cmd_we && (cmd_addr == 8'd21 || cmd_addr == 8'd22);
wire [1:0] s_wa = (cmd_addr == 8'd21) ? 2'd0 : 2'd1;
step_drv u_step (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .reg_wr(s_wr), .reg_addr(s_wa), .reg_data(cmd_wdata[15:0]),
    .dir_in(1'b0), .go(cmd_we && (cmd_addr == 8'd23)),
    .step(s_step), .dir(s_dir), .pos(s_pos),
    .cur_interval(s_int), .busy(s_busy), .done(s_done));

// ---------------- T5: UART RX command parser ---------------------------------
wire [7:0] rx_data;
wire       rx_valid, rx_ferr;
reg        rx_ack = 1'b0;
uart_rx #(.CLK_FRE(27), .BAUD_RATE(115200)) u_rx (
    .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
    .rx_pin(uart_rx_pin), .rx_data(rx_data),
    .rx_valid(rx_valid), .rx_ack(rx_ack), .framing_err(rx_ferr));

reg [2:0]  cmd_st   = 3'd0;
reg [2:0]  cmd_wcnt = 3'd0;
reg [3:0]  probe_sel = 4'd0;

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

// regmap: RW scratch/control; RO results
reg [31:0] scratch = 32'd0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) scratch <= 32'd0;
    else if (cmd_we && cmd_addr == 8'd0) scratch <= cmd_wdata;
end

function [31:0] reg_read;
    input [7:0] a;
    begin
        case (a)
            8'd0:  reg_read = scratch;
            8'd1:  reg_read = {15'd0, rst_glitch, por_cycles};
            8'd2:  reg_read = {14'd0, pll_lock_seen, pll_lock, pll_lock_cycles};
            8'd3:  reg_read = {6'd0, m_done, clk54_ticks}; // quiesced after
                                                          // m_done (stopped
                                                          // in clk54 domain)
            8'd4:  reg_read = csc54_digest;
            8'd5:  reg_read = {6'd0, csc54_done, csc54_pass, 8'd0, csc54_cyc};
            8'd6:  reg_read = {16'd0, cdc_xfers};
            8'd7:  reg_read = {16'd0, cdc_errs};
            8'd8:  reg_read = {16'd0, meta_dis};
            8'd9:  reg_read = {16'd0, meta_samp};
            8'd10: reg_read = {24'd0, cdc_lat};
            8'd11: reg_read = {16'd0, t3_cyc};
            8'd12: reg_read = {14'd0, t3_done, t3_pass, 16'd0};
            8'd13: reg_read = t3_digest;
            8'd14: reg_read = {14'd0, edge_tmr_ok, edge_wdt_ok,
                               w_cg[3:0], w_ce[3:0], w_cl[3:0], w_ct[3:0]};
            8'd15: reg_read = {15'd0, t_done, t_errc};
            8'd16: reg_read = {28'd0, probe_sel};
            8'd17: reg_read = q_cnt;
            8'd18: reg_read = {14'd0, q_dir, s_busy, s_pos};
            8'd19: reg_read = {16'd0, s_int};
            8'd20: reg_read = csc33_digest;
            8'd21: reg_read = {6'd0, csc33_done, csc33_pass, 8'd0, csc33_cyc};
            8'd22: reg_read = {30'd0, pll33_lock, 1'b0};
            8'd31: reg_read = 32'h4837_5632;          // "HV2" magic
            default: reg_read = 32'hDEAD_0000 | {24'd0, a};
        endcase
    end
endfunction

// ---------------- UART TX: reply engine (FIFO + formatter) --------------------
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

// formatter: R-reply = 12B "R=XXXXXXXX\r\n"; T-report = 16 regs x 13B
//            "Rn=XXXXXXXX   \r\n"
reg       f_on = 1'b0;
reg [1:0] f_kind = 2'd0;          // 1=R, 2=T
reg [7:0] f_i = 8'd0;             // byte index within reply
reg [31:0] f_word = 32'd0;
reg [4:0] f_reg = 5'd0;

wire fmt_push;                    // formatter pushes one byte/clk
reg  [7:0] fmt_byte = 8'd0;
reg  fmt_push_r = 1'b0;

reg [3:0] f_pos;
always @(*) begin
    // default byte for the current reply position
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
        // 'T' report: per reg 13 bytes: "Rn=XXXXXXXX   \r\n" -> 13? use 12+pad
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
        // launch formatter on command
        if (cmd_re && !f_on) begin
            f_on <= 1'b1; f_kind <= 2'd1; f_i <= 8'd0;
            f_word <= reg_read(cmd_addr); f_reg <= 5'd0;
        end else if (cmd_rep && !f_on) begin
            f_on <= 1'b1; f_kind <= 2'd2; f_i <= 8'd0;
            f_word <= reg_read(8'd0); f_reg <= 5'd0;
        end
        // format one byte per clk into queue
        if (push) begin
            rq[rq_w] <= fmt_byte;
            rq_w <= rq_w + 6'd1;
            if (f_i[3:0] == 4'd12 && f_kind == 2'd2) begin
                f_i <= 8'd0;
                f_reg <= f_reg + 5'd1;
                f_word <= reg_read({3'b0, f_reg} + 8'd1);
            end else begin
                f_i <= f_i + 8'd1;
            end
            if (fmt_done) f_on <= 1'b0;
        end
        // pop side: latch byte for uart
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

// ---------------- probe mux ----------------------------------------------------
reg hb = 1'b0;
reg [22:0] hb_c = 23'd0;
always @(posedge clk) begin
    hb_c <= hb_c + 23'd1;
    if (hb_c == 23'd0) hb <= ~hb;
end

// clk54 divided marker for the LA (54 MHz is too fast for cheap probes)
reg [3:0] c54_c = 4'd0;
reg       clk54_div = 1'b0;
always @(posedge clk54) begin
    c54_c <= c54_c + 4'd1;
    if (c54_c == 4'd0) clk54_div <= ~clk54_div;
end

reg [7:0] dbg_r;
always @(*) begin
    case (probe_sel)
        // reset/pll/cdc view
        4'd0: dbg_r = {hb, rst_n, rst_s2, pll_lock, osc_clk,
                       c_req_s[1], c_ack, uart_tx};
        // datapath view: CSC27 activity
        4'd1: dbg_r = {hb, t3_start, t3_cyc[3:0], t3_done, t3_pass, tx_busy};
        // low-speed outputs
        4'd2: dbg_r = {hb, pwm_o[0], s_step, s_dir, q_a, q_b,
                       w_reset_req, t_err};
        // 54 MHz domain + metastability taps
        4'd3: dbg_r = {hb, clk54_div, csc54_done, csc54_pass, osc_clk,
                       ma, ma2, meta_dis[0]};
        // command/bus activity
        4'd4: dbg_r = {hb, rx_valid, rx_ferr, cmd_we, cmd_re, cmd_rep,
                       tx_busy, uart_tx};
        default: dbg_r = {hb, probe_sel[2:0], 4'b1010};
    endcase
end
assign {dbg7, dbg6, dbg5, dbg4, dbg3, dbg2, dbg1, dbg0} = dbg_r;

// ---------------- aggregate status --------------------------------------------
// aggregate gates only the in-spec tests; the 54 MHz run is a margin probe
wire hw_done = t3_done && csc54_done && csc33_done && (w_st == 4'd15) &&
               t_done && m_done;
wire hw_pass = t3_pass && csc33_pass && edge_wdt_ok && edge_tmr_ok &&
               (cdc_errs == 16'd0) && (t3_digest === 32'hCE41D92D) &&
               (csc33_digest === 32'hCE41D92D);
assign status_pass = hw_done && hw_pass;
assign status_fail = hw_done && !hw_pass;

endmodule
