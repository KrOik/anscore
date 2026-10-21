`timescale 1ns / 1ps
// tb_ips_irq_priority_ctrl : production-line testbench for the 16-line nested
// priority interrupt controller.
//
// Folding rule (the identical rule is stated in models/ips_irq_priority_ctrl.py):
//   one FNV-1a pass of NINE words per ENABLED beat, in this order
//     W0 = {16'd0, bus_rdata}
//     W1 = {       mask_r,        pend}
//     W2 = {       swtrig,        inact}
//     W3 = {19'd0, bus_ack, nest_depth, cur_pri, irq_pri}
//     W4 = {24'd0, irq_vec}
//     W5 = {24'd0, err_code, irq_req, blocked, nested, ge}
//     W6 = {11'd0, err_count, svc_cnt, eoi_cnt}
//     W7 = stk_flat[63:32]
//     W8 = stk_flat[31:0]
//   then the tail: {25'd0, err_count}, {25'd0, svc_cnt}, {25'd0, eoi_cnt},
//                  {20'd0, nest_depth, cur_pri, err_code}, {28'd0, BEATS}.
// Inputs are never folded; only DUT outputs are.  The expected stream is NOT
// written here -- models/ips_irq_priority_ctrl.py computes it independently from
// the contract in src/ips_irq_priority_ctrl.v (trap T1).  Every check uses ===
// so an X can never read as a pass (trap T6).
//
// The DUT is instantiated with NO parameter override, so every parameter must
// reach the digest through its shipped default.
//
// Stimulus contract (mirrored by the model).  clk_en comes from a free-running
// 5-state divisor (div_q 0..TB_DIV, tick when div_q == 0), so exactly one enabled
// posedge happens per loop iteration.  Beat i is the (i+1)-th enabled posedge
// after reset.  Inputs are a function of i only, plus one LCG step per beat:
//   rstate = rstate * 32'd1664525 + 32'd1013904223;   seed 32'h0BADC0DE
//   A  i <   8 : quiet, every input 0.
//   B  i <  72 : one line per 4-beat slot, slot = (i - 8) / 4 = 0..15, s = i % 4.
//                s = 0,1 drive irq_in = 16'h0001 << slot, s = 2 idle,
//                s = 3 write PEND (address 2) with wdata = 16'h0001 << slot.
//                No svc_ack, no eoi: every line is vectored on its own and then
//                write-1-cleared, and lines 8 and 9 stay invisible because the
//                reset mask holds them.
//   C  i < 112 : masking.  i = 72 writes MASK = 16'hFFFF.  73 <= i < 89 drives
//                irq_in = 16'h0001 << ((i - 73) % 16) (2 beats per line), so every
//                line arms pend while nothing may vector.  i = 90 writes
//                MASK = 16'h00FF, 91 <= i < 107 drives 16'h0001 << ((i-91) % 8) so
//                lines 0..7 become candidates and 8..15 do not.  i = 108 writes
//                MASK = 16'h0000, i = 109 writes PEND = 16'hFFFF (clear all),
//                i = 110,111 idle.
//   D  i < 240 : nesting and every error arm.  A running hold word is OR-written
//                by 16'h8000, 16'h4000, ... 16'h0200 at i = 112,120,...,160 (lines
//                15 down to 9) and 16'h0100 at 168, and cleared at 178;
//                irq_in = hold for 112 <= i < 178 and 0 afterwards.  svc_ack
//                fires at i = 118,126,...,166 (one accept per slot, so seven
//                accepts nest to depth NEST_MAX), at 174 (line 8 is the candidate
//                at full depth -> overflow refused) and at 216 and 228 for the
//                single software-triggered lines.  eoi fires at 180,184,...,204
//                naming 9,10,...,15 in LIFO order, at 220 naming 6, at 236 naming
//                5, wrongly at 198 (line 0 while line 12 is in service) and at
//                232 (line 4 while line 5 is in service), and at 208 with the
//                stack already empty.  i = 176 writes PEND = 16'hFF00, i = 206
//                writes the ILLEGAL address 4'hC with we = 1, i = 212 writes
//                SWTRIG = 16'h0040 with every pin low (a software-only vector),
//                i = 224 writes SWTRIG = 16'h0020 and i = 232 writes
//                SWTRIG = 16'h0080 (line 7 behind line 5 -> blocked).
//   E  i >= 240: LCG fuzz, one step per beat:
//                irq_in = rstate[15:0], bus_addr = rstate[19:16],
//                bus_we = rstate[20], svc_ack = rstate[21], eoi = rstate[22],
//                eoi_idx = rstate[26:23], bus_wdata = rstate[31:16].
module tb_ips_irq_priority_ctrl;

`include "ips_tb_common.vh"

localparam integer BEATS    = 600;
localparam [3:0]   TB_DIV   = 4'd4;
localparam [2:0]   TB_NMAX  = 3'd7;      // shipped NEST_MAX default
localparam [3:0]   TB_ERR   = 4'h8;      // shipped ERR_BASE default
localparam [3:0]   TB_LAST  = 4'h5;      // last legal register address
localparam [6:0]   TB_SAT   = 7'd100;    // shipped CNT_SAT default

reg         rst_n;
reg  [3:0]  div_q;
reg  [31:0] rstate;
integer     i;
reg         bad;

// driven inputs of the beat in progress, kept for the checks that follow
reg  [15:0] d_pin;
reg  [3:0]  d_addr;
reg         d_we;
reg  [15:0] d_wdata;
reg         d_svc;
reg         d_eoi;
reg  [3:0]  d_eidx;

// pre-edge images of the outputs the beat is allowed to move
reg  [2:0]  p_nd;
reg  [4:0]  p_pri;
reg  [15:0] p_mask;
reg  [15:0] p_pend;
reg  [15:0] p_sw;
reg  [3:0]  p_ipri;
reg         p_req;
reg  [6:0]  p_errc;
reg  [6:0]  p_svc;
reg  [6:0]  p_eoi;
reg  [3:0]  p_errcode;
reg  [63:0] p_stk;

// stimulus bookkeeping
reg  [15:0] hold;
reg  [15:0] req_union;
reg  [15:0] exp_sw;
reg  [6:0]  exp_err;

// coverage of the required behaviours
reg         saw_vec0, saw_vec15, saw_blocked, saw_nest, saw_pop;
reg         saw_sw_vec, saw_inact, saw_err_eoi, saw_err_idle, saw_err_oflow;
reg         saw_err_addr, saw_w1c, saw_unmask_vec;

wire        tick;
wire [15:0] bus_rdata;
wire        bus_ack;
wire [7:0]  irq_vec;
wire [3:0]  irq_pri;
wire        irq_req;
wire        blocked;
wire        ge;
wire        nested;
wire [2:0]  nest_depth;
wire [4:0]  cur_pri;
wire [15:0] pend;
wire [15:0] mask_r;
wire [15:0] swtrig;
wire [15:0] inact;
wire [3:0]  err_code;
wire [6:0]  err_count;
wire [6:0]  svc_cnt;
wire [6:0]  eoi_cnt;
wire [63:0] stk_flat;

assign tick = (div_q == 4'd0);

always @(posedge ips_clk) begin
    div_q <= (div_q == TB_DIV) ? 4'd0 : (div_q + 4'd1);
end

ips_irq_priority_ctrl dut (
    .clk        (ips_clk),
    .clk_en     (tick),
    .rst_n      (rst_n),
    .irq_in     (d_pin),
    .bus_addr   (d_addr),
    .bus_we     (d_we),
    .bus_wdata  (d_wdata),
    .svc_ack    (d_svc),
    .eoi        (d_eoi),
    .eoi_idx    (d_eidx),
    .bus_rdata  (bus_rdata),
    .bus_ack    (bus_ack),
    .irq_vec    (irq_vec),
    .irq_pri    (irq_pri),
    .irq_req    (irq_req),
    .blocked    (blocked),
    .ge         (ge),
    .nested     (nested),
    .nest_depth (nest_depth),
    .cur_pri    (cur_pri),
    .pend       (pend),
    .mask_r     (mask_r),
    .swtrig     (swtrig),
    .inact      (inact),
    .err_code   (err_code),
    .err_count  (err_count),
    .svc_cnt    (svc_cnt),
    .eoi_cnt    (eoi_cnt),
    .stk_flat   (stk_flat)
);

always @(posedge ips_clk) begin
    if (tick === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// Land on the negedge that opens an enabled beat window.
task beat;
begin
    @(negedge ips_clk);
    while (tick !== 1'b1) begin
        @(negedge ips_clk);
    end
end
endtask

// One directed stimulus slot of phase D: the tables below are plain functions of
// the beat index, so the model can replay them without reading the DUT.
task drive;
    input [15:0] pin;
    input [3:0]  addr;
    input        we;
    input [15:0] wdata;
    input        svc;
    input        eo;
    input [3:0]  eidx;
begin
    d_pin   = pin;
    d_addr  = addr;
    d_we    = we;
    d_wdata = wdata;
    d_svc   = svc;
    d_eoi   = eo;
    d_eidx  = eidx;
end
endtask

initial begin
    ips_fnv_reset();
    rst_n    = 1'b0;
    div_q    = 4'd0;
    rstate   = 32'h0BADC0DE;
    hold     = 16'h0000;
    req_union= 16'h0000;
    bad      = 1'b0;
    saw_vec0 = 1'b0;  saw_vec15 = 1'b0; saw_blocked = 1'b0;
    saw_nest = 1'b0;  saw_pop   = 1'b0; saw_sw_vec  = 1'b0;
    saw_inact = 1'b0; saw_err_eoi = 1'b0; saw_err_idle = 1'b0;
    saw_err_oflow = 1'b0; saw_err_addr = 1'b0; saw_w1c = 1'b0;
    saw_unmask_vec = 1'b0;
    d_pin = 16'h0000; d_addr = 4'h0; d_we = 1'b0; d_wdata = 16'h0000;
    d_svc = 1'b0;     d_eoi  = 1'b0; d_eidx = 4'h0;

    repeat (4) @(negedge ips_clk);
    // Release reset in the closed window right after an enabled edge that the core
    // still spent in reset, so the first enabled beat of the loop is also the
    // first beat the model replays.
    beat;
    @(negedge ips_clk);
    rst_n = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        beat;

        // ---- pre-edge images of everything this beat may move ---------------
        p_nd      = nest_depth;
        p_pri     = cur_pri;
        p_mask    = mask_r;
        p_pend    = pend;
        p_sw      = swtrig;
        p_ipri    = irq_pri;
        p_req     = irq_req;
        p_errc    = err_count;
        p_svc     = svc_cnt;
        p_eoi     = eoi_cnt;
        p_errcode = err_code;
        p_stk     = stk_flat;
        // err_count steps once per error beat and saturates at TB_SAT
        exp_err   = (p_errc < TB_SAT) ? (p_errc + 7'd1) : p_errc;

        // ---- stimulus for this beat ----------------------------------------
        rstate = rstate * 32'd1664525 + 32'd1013904223;
        drive(16'h0000, 4'h0, 1'b0, 16'h0000, 1'b0, 1'b0, 4'h0);
        if (i >= 8 && i < 72) begin
            // phase B: one line per 4-beat slot, then write-1-clear it
            if (((i - 8) % 4) != 3) begin
                if (((i - 8) % 4) < 2) begin
                    d_pin = 16'h0001 << ((i - 8) / 4);
                end
            end else begin
                d_addr  = 4'h2;
                d_we    = 1'b1;
                d_wdata = 16'h0001 << ((i - 8) / 4);
            end
        end else if (i >= 72 && i < 112) begin
            // phase C: masking
            if (i == 72) begin
                d_addr = 4'h0; d_we = 1'b1; d_wdata = 16'hFFFF;
            end else if (i >= 73 && i < 89) begin
                d_pin = 16'h0001 << ((i - 73) % 16);
            end else if (i == 90) begin
                d_addr = 4'h0; d_we = 1'b1; d_wdata = 16'h00FF;
            end else if (i >= 91 && i < 107) begin
                d_pin = 16'h0001 << ((i - 91) % 8);
            end else if (i == 108) begin
                d_addr = 4'h0; d_we = 1'b1; d_wdata = 16'h0000;
            end else if (i == 109) begin
                d_addr = 4'h2; d_we = 1'b1; d_wdata = 16'hFFFF;
            end
        end else if (i >= 112 && i < 240) begin
            // phase D: nesting, pops, every error arm
            if (i == 112) hold = hold | 16'h8000;
            if (i == 120) hold = hold | 16'h4000;
            if (i == 128) hold = hold | 16'h2000;
            if (i == 136) hold = hold | 16'h1000;
            if (i == 144) hold = hold | 16'h0800;
            if (i == 152) hold = hold | 16'h0400;
            if (i == 160) hold = hold | 16'h0200;
            if (i == 168) hold = hold | 16'h0100;
            if (i == 178) hold = 16'h0000;
            if (i >= 112 && i < 178) begin
                d_pin = hold;
            end
            if (i == 174 || i == 216 || i == 228) begin
                d_svc = 1'b1;
            end else if (i >= 118 && i < 168 && ((i - 118) % 8) == 0) begin
                d_svc = 1'b1;
            end
            if (i >= 180 && i <= 204 && ((i - 180) % 4) == 0) begin
                d_eoi  = 1'b1;
                d_eidx = 4'd9 + ((i - 180) / 4);
            end else if (i == 198) begin
                d_eoi  = 1'b1;
                d_eidx = 4'd0;
            end else if (i == 208) begin
                d_eoi  = 1'b1;
                d_eidx = 4'd0;
            end else if (i == 220) begin
                d_eoi  = 1'b1;
                d_eidx = 4'd6;
            end else if (i == 232) begin
                d_eoi  = 1'b1;
                d_eidx = 4'd4;
            end else if (i == 236) begin
                d_eoi  = 1'b1;
                d_eidx = 4'd5;
            end
            if (i == 176) begin
                d_addr = 4'h2; d_we = 1'b1; d_wdata = 16'hFF00;
            end else if (i == 206) begin
                d_addr = 4'hC; d_we = 1'b1; d_wdata = 16'h5A5A;
            end else if (i == 212) begin
                d_addr = 4'h1; d_we = 1'b1; d_wdata = 16'h0040;
            end else if (i == 224) begin
                d_addr = 4'h1; d_we = 1'b1; d_wdata = 16'h0020;
            end else if (i == 232) begin
                d_addr = 4'h1; d_we = 1'b1; d_wdata = 16'h0080;
            end
        end else if (i >= 240) begin
            // phase E: LCG fuzz
            d_pin   = rstate[15:0];
            d_addr  = rstate[19:16];
            d_we    = rstate[20];
            d_wdata = rstate[31:16];
            d_svc   = rstate[21];
            d_eoi   = rstate[22];
            d_eidx  = rstate[26:23];
        end

        req_union = req_union | d_pin;
        if (d_we && d_addr == 4'h1) begin
            req_union = req_union | d_wdata;
        end

        @(negedge ips_clk);

        // ---- X hygiene (trap T6): nothing below may be evaluated on an X -----
        if ((^bus_rdata === 1'bx) || (^irq_vec === 1'bx) || (^pend === 1'bx) ||
            (^mask_r === 1'bx) || (^swtrig === 1'bx) || (^inact === 1'bx) ||
            (^stk_flat === 1'bx) || (^cur_pri === 1'bx) ||
            (^nest_depth === 1'bx) || (^err_code === 1'bx) ||
            (^err_count === 1'bx) || (^svc_cnt === 1'bx) ||
            (^eoi_cnt === 1'bx) || (^irq_req === 1'bx) || (^blocked === 1'bx) ||
            (^nested === 1'bx) || (^ge === 1'bx) || (^bus_ack === 1'bx)) begin
            bad = 1'b1;
        end

        // ---- irq_vec is the published index with the vector base attached ----
        if (irq_vec[3:0] !== irq_pri) begin
            bad = 1'b1;
        end

        // ---- a request and a block are mutually exclusive --------------------
        if (irq_req === 1'b1 && blocked === 1'b1) begin
            bad = 1'b1;
        end

        // ---- masked lines never vector: the beat that published this request
        //      ran under the mask that was in force before its edge, and the
        //      vectored line must have been asked for at some point
        if (irq_req === 1'b1) begin
            if (p_mask[irq_vec[3:0]] === 1'b1) begin
                bad = 1'b1;
            end
            if (req_union[irq_vec[3:0]] !== 1'b1) begin
                bad = 1'b1;
            end
            if (irq_vec[3:0] === 4'd0) begin
                saw_vec0 = 1'b1;
            end
            if (irq_vec[3:0] === 4'd15) begin
                saw_vec15 = 1'b1;
            end
            if (p_sw[irq_vec[3:0]] === 1'b1 && p_pend[irq_vec[3:0]] === 1'b0 &&
                d_pin[irq_vec[3:0]] === 1'b0) begin
                saw_sw_vec = 1'b1;
            end
        end
        if (blocked === 1'b1) begin
            saw_blocked = 1'b1;
        end
        if (inact !== 16'h0000) begin
            saw_inact = 1'b1;
        end

        // ---- accept path: nesting, ceiling, stack push, counter --------------
        if (d_svc === 1'b1 && d_eoi === 1'b0 && p_req === 1'b1 &&
            p_nd < TB_NMAX) begin
            if (nest_depth !== (p_nd + 3'd1)) begin
                bad = 1'b1;
            end
            if (cur_pri !== {1'b0, p_ipri}) begin
                bad = 1'b1;
            end
            if (nested !== (p_nd != 3'd0)) begin
                bad = 1'b1;
            end
            if (svc_cnt !== (p_svc + 7'd1)) begin
                bad = 1'b1;
            end
            if (stk_flat[(p_nd * 8) +: 5] !== p_pri) begin
                bad = 1'b1;
            end
            if (p_nd != 3'd0) begin
                saw_nest = 1'b1;
            end
        end

        // ---- accept refused because the nesting stack is full ---------------
        if (d_svc === 1'b1 && d_eoi === 1'b0 && p_req === 1'b1 &&
            p_nd == TB_NMAX) begin
            if (nest_depth !== p_nd || cur_pri !== p_pri) begin
                bad = 1'b1;
            end
            if (svc_cnt !== p_svc) begin
                bad = 1'b1;
            end
            if (err_code !== (TB_ERR + 4'd3)) begin
                bad = 1'b1;
            end
            if (err_count !== exp_err) begin
                bad = 1'b1;
            end
            saw_err_oflow = 1'b1;
        end

        // ---- legal EOI pops to the parent priority --------------------------
        if (d_eoi === 1'b1 && p_nd != 3'd0 && d_eidx === p_pri[3:0]) begin
            if (nest_depth !== (p_nd - 3'd1)) begin
                bad = 1'b1;
            end
            if (cur_pri !== p_stk[((p_nd - 3'd1) * 8) +: 5]) begin
                bad = 1'b1;
            end
            if (eoi_cnt !== (p_eoi + 7'd1)) begin
                bad = 1'b1;
            end
            if (nested !== 1'b0) begin
                bad = 1'b1;
            end
            if (p_nd != 3'd1) begin
                saw_pop = 1'b1;
            end
        end

        // ---- illegal EOI arms must flag and must not corrupt ----------------
        if (d_eoi === 1'b1 && d_svc === 1'b0 && d_we === 1'b0) begin
            if (p_nd == 3'd0) begin
                if (err_code !== (TB_ERR + 4'd1)) begin
                    bad = 1'b1;
                end
                saw_err_idle = 1'b1;
            end else if (d_eidx !== p_pri[3:0]) begin
                if (err_code !== (TB_ERR + 4'd2)) begin
                    bad = 1'b1;
                end
                saw_err_eoi = 1'b1;
            end
            if ((p_nd == 3'd0 || d_eidx !== p_pri[3:0]) &&
                (nest_depth !== p_nd || cur_pri !== p_pri)) begin
                bad = 1'b1;
            end
            if ((p_nd == 3'd0 || d_eidx !== p_pri[3:0]) &&
                err_count !== exp_err) begin
                bad = 1'b1;
            end
        end

        // ---- an illegal address must not touch a live register --------------
        if (d_we === 1'b1 && d_addr > TB_LAST) begin
            if (err_code !== TB_ERR) begin
                bad = 1'b1;
            end
            if (err_count !== exp_err) begin
                bad = 1'b1;
            end
            if (d_eoi === 1'b0 && d_svc === 1'b0 &&
                (mask_r !== p_mask || nest_depth !== p_nd || cur_pri !== p_pri ||
                 svc_cnt !== p_svc || eoi_cnt !== p_eoi)) begin
                bad = 1'b1;
            end
            saw_err_addr = 1'b1;
        end

        // ---- write strobes that are legal do reach their register -----------
        if (d_we === 1'b1 && d_addr <= TB_LAST) begin
            if (d_addr == 4'h0 && mask_r !== d_wdata) begin
                bad = 1'b1;
            end
            if (d_addr == 4'h2) begin
                saw_w1c = 1'b1;
            end
        end
        // swtrig is write-1-to-set and loses exactly the accepted line
        exp_sw = p_sw;
        if (d_we === 1'b1 && d_addr == 4'h1) begin
            exp_sw = exp_sw | d_wdata;
        end
        if (d_svc === 1'b1 && d_eoi === 1'b0 && p_req === 1'b1 &&
            p_nd < TB_NMAX) begin
            exp_sw = exp_sw & ~(16'h0001 << p_ipri);
        end
        if (swtrig !== exp_sw) begin
            bad = 1'b1;
        end

        // ---- bus_ack marks exactly the legal writes -------------------------
        if (bus_ack !== (d_we && (d_addr <= TB_LAST))) begin
            bad = 1'b1;
        end

        // ---- the mask write of phase C unmasks a line that then vectors -----
        if (i >= 91 && i < 107 && irq_req === 1'b1) begin
            saw_unmask_vec = 1'b1;
        end

        ips_fnv_word({16'd0, bus_rdata});
        ips_fnv_word({mask_r, pend});
        ips_fnv_word({swtrig, inact});
        ips_fnv_word({19'd0, bus_ack, nest_depth, cur_pri, irq_pri});
        ips_fnv_word({24'd0, irq_vec});
        ips_fnv_word({24'd0, err_code, irq_req, blocked, nested, ge});
        ips_fnv_word({11'd0, err_count, svc_cnt, eoi_cnt});
        ips_fnv_word(stk_flat[63:32]);
        ips_fnv_word(stk_flat[31:0]);
    end

    repeat (2) @(negedge ips_clk);
    ips_fnv_word({25'd0, err_count});
    ips_fnv_word({25'd0, svc_cnt});
    ips_fnv_word({25'd0, eoi_cnt});
    ips_fnv_word({20'd0, nest_depth, cur_pri, err_code});
    ips_fnv_word(BEATS);

    // The directed set must actually have exercised every required behaviour,
    // or this testbench would be vacuous even though it folds 600 beats.
    if (saw_vec0 === 1'b0 || saw_vec15 === 1'b0 || saw_blocked === 1'b0 ||
        saw_nest === 1'b0 || saw_pop === 1'b0 || saw_sw_vec === 1'b0 ||
        saw_inact === 1'b0 || saw_err_eoi === 1'b0 ||
        saw_err_idle === 1'b0 || saw_err_oflow === 1'b0 ||
        saw_err_addr === 1'b0 || saw_w1c === 1'b0 ||
        saw_unmask_vec === 1'b0) begin
        bad = 1'b1;
    end

    ips_verdict(!bad, "ips_irq_priority_ctrl");
end

endmodule
