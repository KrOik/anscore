`timescale 1ns / 1ps
// tb_ips_kbd_matrix_scan : production-line testbench for the 8x8 matrix scanner.
//
// Folding rule (identical rule is stated in models/ips_kbd_matrix_scan.py):
//   one FNV-1a pass of FOUR words per ENABLED beat, in this order
//     W0 = {17'd0, code_slot[6:0],  key_code[7:0]}
//     W1 = {16'd0, rel_code[7:0],  press_code[7:0]}
//     W2 = { 5'd0, rel_cnt[5:0],  press_cnt[5:0], key_count[6:0], phantom_code[7:0]}
//     W3 = {11'd0, scan_cnt[7:0],  scan_col[3:0], phase[1:0], stuck_flag,
//            nk_over, ghost_flag, report_done, code_valid, press_col, rel_col}
//   then the tail: {25'd0, key_count}, {20'd0, rel_cnt, press_cnt},
//                   {24'd0, scan_cnt}, {29'd0, ghost_flag, nk_over, stuck_flag},
//                   {28'd0, BEATS}.
// Inputs are never folded; only DUT outputs are.  The expected stream is NOT
// written here -- models/ips_kbd_matrix_scan.py computes it independently from the
// contract in src/ips_kbd_matrix_scan.v (trap T1).  All checks use === so an X can
// never read as a pass (trap T6).
//
// Stimulus contract (mirrored by the model).  clk_en comes from a free-running
// 5-state divisor (div_q 0..TB_DIV, tick when div_q == 0), so exactly one enabled
// posedge happens per loop iteration.  The key set is a 64-bit column-major map, byte c
// holding the rows closed in column c.  Episode e is applied for exactly one scan
// cycle: the testbench swaps to episode e+1 on the beat that reports report_done.
//   EP0  {}                                   idle baseline, no codes
//   EP1  {(2,3)}                               single press
//   EP2  {(2,3)}                               held -> repeat, press must drop
//   EP3  {}                                   release transition
//   EP4  {(1,1),(5,7)}                         two keys, no ghost
//   EP5  {(0,0),(0,4),(3,0)}                  3-key L -> phantom (3,4)
//   EP6  {(0,0),(0,4),(3,0),(3,4)}            full rectangle, no phantom
//   EP7  {(0,0),(0,4),(3,0)}                  ghost again, this time over EP6
//   EP8  {(0,0)..(5,5)} matching               N-key rollover == NKR_MAX
//   EP9  {(0,0)..(6,6)} matching               roll-over EXCEEDED (7 > 6)
//   EP10 {}                                   every key released
//   EP11 column 5 shorted (row_in == 8'hFF)    stuck flag, no false ghost
//   EP12.. LCG random 1..4 closures:
//        rstate = rstate*32'd1664525 + 32'd1013904223;  nk = 1 + rstate[7:6]
//        per key: one more step, row = rstate[2:0], col = rstate[6:4],
//                 set bit (col*8 + row)
//   rstate seeds at 32'hBADCAFE0 and only moves inside the random generator.
module tb_ips_kbd_matrix_scan;

`include "ips_tb_common.vh"

localparam integer BEATS = 600;
localparam [3:0]   TB_DIV   = 4'd4;
localparam [7:0]   TB_BASE  = 8'h21;      // shipped CODE_BASE default
localparam [3:0]   TB_NKR   = 4'd6;       // shipped NKR_MAX default
localparam [1:0]   TB_EMIT  = 2'd2;       // core emit phase encoding

reg         rst_n;
reg  [3:0]  div_q;
reg  [63:0] kmap;
reg  [63:0] kmap_prev;
reg  [31:0] rstate;
reg  [2:0]  rr;
reg  [2:0]  cc;
integer     ep;
integer     ngen;
integer     kk;

wire        tick;
wire [7:0]  row_in;
wire [7:0]  col_drv;
wire [3:0]  scan_col;
wire [1:0]  phase;
wire [7:0]  key_code;
wire        code_valid;
wire [6:0]  code_slot;
wire [6:0]  key_count;
wire        press_col;
wire        rel_col;
wire [7:0]  press_code;
wire [7:0]  rel_code;
wire [5:0]  press_cnt;
wire [5:0]  rel_cnt;
wire        ghost_flag;
wire [7:0]  phantom_code;
wire        nk_over;
wire        stuck_flag;
wire        report_done;
wire [7:0]  scan_cnt;

assign tick = (div_q == 4'd0);

always @(posedge ips_clk) begin
    div_q <= (div_q == TB_DIV) ? 4'd0 : (div_q + 4'd1);
end

// The pad model: a closed key ties the sensed row to the driven column, so the
// sensed row byte is exactly the cmap byte of the driven column.  No debounce, no
// chatter: the row byte only changes when the core changes col_drv or the episode
// changes.
reg [2:0]  dc;
always @* begin
    dc = 3'd0;
    case (col_drv)
        8'h01:   dc = 3'd0;
        8'h02:   dc = 3'd1;
        8'h04:   dc = 3'd2;
        8'h08:   dc = 3'd3;
        8'h10:   dc = 3'd4;
        8'h20:   dc = 3'd5;
        8'h40:   dc = 3'd6;
        8'h80:   dc = 3'd7;
        default: dc = 3'd0;
    endcase
end
assign row_in = kmap[{dc, 3'b000} +: 8];

ips_kbd_matrix_scan dut (
    .clk         (ips_clk),
    .clk_en      (tick),
    .rst_n       (rst_n),
    .row_in      (row_in),
    .col_drv     (col_drv),
    .scan_col    (scan_col),
    .phase       (phase),
    .key_code    (key_code),
    .code_valid  (code_valid),
    .code_slot   (code_slot),
    .key_count   (key_count),
    .press_col   (press_col),
    .rel_col     (rel_col),
    .press_code  (press_code),
    .rel_code    (rel_code),
    .press_cnt   (press_cnt),
    .rel_cnt     (rel_cnt),
    .ghost_flag  (ghost_flag),
    .phantom_code(phantom_code),
    .nk_over     (nk_over),
    .stuck_flag  (stuck_flag),
    .report_done (report_done),
    .scan_cnt    (scan_cnt)
);

always @(posedge ips_clk) begin
    if (tick === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
reg     bad;
reg [7:0]  pi;
reg [3:0]  pc1;
reg [3:0]  pr;
reg [2:0]  pc;
reg [2:0]  ppr;
reg        okp;
reg        share;
reg     saw_code;
reg     saw_ghost;
reg     saw_press;
reg     saw_rel;
reg     saw_over;
reg     saw_stuck;
reg     in_report;
reg     prev_valid;
reg [6:0] prev_slot;

function [6:0] pop64;
    input [63:0] v;
    integer j;
    begin
        pop64 = 7'd0;
        for (j = 0; j < 64; j = j + 1) begin
            if (v[j]) begin
                pop64 = pop64 + 7'd1;
            end
        end
    end
endfunction

// Episode table: one scan cycle per closure set.
task apply_episode;
    input integer e;
    begin
        case (e)
            0:       kmap = 64'h0000000000000000;
            1:       kmap = 64'h0000000004000000;
            2:       kmap = 64'h0000000004000000;
            3:       kmap = 64'h0000000000000000;
            4:       kmap = 64'h2000000000000200;
            5:       kmap = 64'h0000000100000009;
            6:       kmap = 64'h0000000900000009;
            7:       kmap = 64'h0000000100000009;
            8:       kmap = 64'h0000201008040201;
            9:       kmap = 64'h0040201008040201;
            10:      kmap = 64'h0000000000000000;
            11:      kmap = 64'h0000FF0000000000;
            default: begin
                rstate = rstate * 32'd1664525 + 32'd1013904223;
                ngen   = 1 + rstate[7:6];
                kmap   = 64'h0000000000000000;
                for (kk = 0; kk < ngen; kk = kk + 1) begin
                    rstate = rstate * 32'd1664525 + 32'd1013904223;
                    rr     = rstate[2:0];
                    cc     = rstate[6:4];
                    kmap[cc * 8 + rr] = 1'b1;
                end
            end
        endcase
    end
endtask

// Land on the negedge that opens an enabled beat window.
task beat;
begin
    @(negedge ips_clk);
    while (tick !== 1'b1) begin
        @(negedge ips_clk);
    end
end
endtask

initial begin
    ips_fnv_reset();
    rst_n      = 1'b0;
    div_q      = 4'd0;
    kmap       = 64'h0000000000000000;
    kmap_prev  = 64'h0000000000000000;
    rstate     = 32'hBADCAFE0;
    ep         = 0;
    bad        = 1'b0;
    saw_code   = 1'b0;
    saw_ghost  = 1'b0;
    saw_press  = 1'b0;
    saw_rel    = 1'b0;
    saw_over   = 1'b0;
    saw_stuck  = 1'b0;
    in_report  = 1'b0;
    prev_valid = 1'b0;
    prev_slot  = 7'd0;

    apply_episode(0);
    repeat (4) @(negedge ips_clk);
    // Release reset in the closed window right after an enabled edge that the core
    // still spent in reset, so the first enabled beat of the loop is also the
    // first beat the model replays.
    beat;
    @(negedge ips_clk);
    rst_n = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        beat;
        // kmap for this beat was chosen at the end of the previous iteration.

        @(negedge ips_clk);

        // ---- X hygiene (trap T6): nothing below may be evaluated against an X ----
        if ((^key_code === 1'bx) || (^phantom_code === 1'bx) ||
            (^press_code === 1'bx) || (^rel_code === 1'bx) ||
            (^phase === 1'bx) || (^scan_col === 1'bx) || (^scan_cnt === 1'bx) ||
            (^code_slot === 1'bx) || (^key_count === 1'bx) ||
            ((^press_cnt === 1'bx) || (^rel_cnt === 1'bx))) begin
            bad = 1'b1;
        end

        // ---- no spurious codes between scans: codes only exist in the emit phase
        if (code_valid === 1'b1 && phase !== TB_EMIT) begin
            bad = 1'b1;
        end
        if (code_valid === 1'b0 && key_code !== 8'h00) begin
            bad = 1'b1;
        end

        // ---- every emitted code is a real closure of the applied key set, and the
        //      slots are dense and increasing inside one report
        if (code_valid === 1'b1) begin
            saw_code = 1'b1;
            if (key_code < TB_BASE || (key_code - TB_BASE) > 8'd63) begin
                bad = 1'b1;
            end else if (kmap[key_code - TB_BASE] !== 1'b1) begin
                bad = 1'b1;
            end
            if (phase === TB_EMIT) begin
                if (in_report === 1'b1) begin
                    if (code_slot !== (prev_slot + 7'd1)) begin
                        bad = 1'b1;
                    end
                end else begin
                    if (code_slot !== 7'd0) begin
                        bad = 1'b1;
                    end
                    in_report = 1'b1;
                end
                prev_slot = code_slot;
            end
        end else begin
            if (phase !== TB_EMIT) begin
                in_report = 1'b0;
            end
        end

        // ---- ghost handling: the phantom corner is predicted, flagged, left out of
        //      the emitted set, and it is genuinely an OPEN corner of the matrix
        //      (it may have been a real key in the previous episode, e.g. the full
        //      rectangle followed by the 3-key L, so only the current map is legal)
        if (ghost_flag === 1'b1) begin
            if (phase === TB_EMIT) begin
                if (phantom_code < TB_BASE || (phantom_code - TB_BASE) > 8'd63) begin
                    bad = 1'b1;
                end else if (kmap[phantom_code - TB_BASE] === 1'b1) begin
                    bad = 1'b1;
                end
                // The reported corner must satisfy the phantom definition against
                // the applied map: some OTHER column closes that row AND shares a
                // closed row with the phantom's own column.  Anything else is a
                // fabricated ghost.  Only inside the emit phase, because the flag
                // stays published during the following scan of a different map.
                if (phantom_code >= TB_BASE &&
                    (phantom_code - TB_BASE) <= 8'd63) begin
                    pi  = phantom_code - TB_BASE;
                    pc  = pi[6:3];
                    ppr = pi[2:0];
                    okp = 1'b0;
                    for (pc1 = 4'd0; pc1 < 4'd8; pc1 = pc1 + 4'd1) begin
                        share = 1'b0;
                        for (pr = 4'd0; pr < 4'd8; pr = pr + 4'd1) begin
                            if (kmap[{pc1[2:0], pr[2:0]}] === 1'b1 &&
                                kmap[{pc, pr[2:0]}] === 1'b1) begin
                                share = 1'b1;
                            end
                        end
                        if (pc1[2:0] !== pc && kmap[{pc1[2:0], ppr}] === 1'b1 &&
                            share === 1'b1) begin
                            okp = 1'b1;
                        end
                    end
                    if (okp === 1'b0) begin
                        bad = 1'b1;
                    end
                end
            end
            if (code_valid === 1'b1 && key_code === phantom_code) begin
                bad = 1'b1;
            end
            saw_ghost = 1'b1;
        end

        // ---- make / break reporting: a pressed code is closed now, a released code
        //      is open now but was closed in the previous scan cycle
        if (press_col === 1'b1) begin
            saw_press = 1'b1;
            if (press_code < TB_BASE || (press_code - TB_BASE) > 8'd63) begin
                bad = 1'b1;
            end else if (kmap[press_code - TB_BASE] !== 1'b1) begin
                bad = 1'b1;
            end
        end
        if (rel_col === 1'b1) begin
            saw_rel = 1'b1;
            if (rel_code < TB_BASE || (rel_code - TB_BASE) > 8'd63) begin
                bad = 1'b1;
            end else if (kmap[rel_code - TB_BASE] === 1'b1) begin
                bad = 1'b1;
            end else if (kmap_prev[rel_code - TB_BASE] !== 1'b1) begin
                bad = 1'b1;
            end
        end

        // ---- a shorted column must be reported and must not fabricate a ghost
        if (stuck_flag === 1'b1) begin
            saw_stuck = 1'b1;
        end

        // ---- report accounting at the end of a scan cycle: the emitted code count
        //      equals the closure count of the applied set and the roll-over flag
        //      follows the configured limit exactly
        if (report_done === 1'b1) begin
            if (key_count !== pop64(kmap)) begin
                bad = 1'b1;
            end
            if (nk_over !== (pop64(kmap) > {3'd0, TB_NKR})) begin
                bad = 1'b1;
            end
            if (nk_over === 1'b1) begin
                saw_over = 1'b1;
            end
        end

        ips_fnv_word({17'd0, code_slot, key_code});
        ips_fnv_word({16'd0, rel_code, press_code});
        ips_fnv_word({5'd0, rel_cnt, press_cnt, key_count, phantom_code});
        ips_fnv_word({11'd0, scan_cnt, scan_col, phase, stuck_flag, nk_over,
                      ghost_flag, report_done, code_valid, press_col, rel_col});

        // One scan cycle per episode: switch on the beat that published a report.
        if (report_done === 1'b1) begin
            kmap_prev = kmap;
            ep        = ep + 1;
            apply_episode(ep);
        end
    end

    repeat (2) @(negedge ips_clk);
    ips_fnv_word({25'd0, key_count});
    ips_fnv_word({20'd0, rel_cnt, press_cnt});
    ips_fnv_word({24'd0, scan_cnt});
    ips_fnv_word({29'd0, ghost_flag, nk_over, stuck_flag});
    ips_fnv_word(BEATS);

    // The directed set must actually have exercised every reported behaviour, or
    // this testbench would be vacuous even though it folds 600 beats.
    if (saw_code === 1'b0 || saw_ghost === 1'b0 || saw_press === 1'b0 ||
        saw_rel === 1'b0 || saw_over === 1'b0 || saw_stuck === 1'b0) begin
        bad = 1'b1;
    end

    ips_verdict(!bad, "ips_kbd_matrix_scan");
end

endmodule
