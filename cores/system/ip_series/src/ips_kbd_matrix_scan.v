`timescale 1ns / 1ps
// ips_kbd_matrix_scan : 8x8 keyboard matrix scanner with N-key rollover capture
// and ghost (phantom key) detection.
//
// Written contract.  src/ips_kbd_matrix_scan.v and models/ips_kbd_matrix_scan.py
// are both derived from this text; neither is back-filled from simulation output
// (docs/IP_CORE_SOP.md trap T1).  Every register is gated by clk_en and rst_n is
// the active-low asynchronous reset.
//
// Pad interface.  The core drives ONE column at a time through col_drv (one-hot,
// active high) and senses the eight row pads on row_in.  rin = row_in ^ ROW_POL is
// the closure view the matrix logic works on, so an active-low row bus only needs
// ROW_POL.  A key at (row r, column c) is closed exactly when rin[r] = 1 while
// col_drv selects c.  The task's stimulus model is debounce-free, so a column is
// sensed once per scan cycle and no prescaler is needed: the ring delay itself
// gives a full cycle (40 beats with the shipped SUB_EVAL = 2) between two senses
// of the same column.
//
// Flattened matrix as a ROTATING RING (trap T3, and the reason for the ring).
// The 8x8 matrix is one 64-bit vector `ring`, byte s = ring[8s+7 -: 8] holding an
// eight-bit row slice.  Bytes are NOT pinned to columns: every rotating beat moves
// every byte one slot up (ring <= {ring[55:0], inject}), and a one-hot `tok`
// rotates in lockstep to name the column parked in the top byte.  The invariant,
// which holds at the start of every beat, is
//     byte s  carries  column (head - 1 - s) mod 8,   head = enc3(tok)
// so  byte 7 = the column tok drives  and byte 6 = the column that becomes the
// head after the next rotation.  Consequence: no byte mux and no index arithmetic
// is ever needed - the head, the next head and the analyser's candidate group are
// fixed slices (7, 6 and {1,3,5,7}), and the absolute column of any code comes
// from enc3(tok), the three-gate encoder of a one-hot.
// During a scan beat the value parked in byte 7 is the slice captured one full
// cycle earlier for that same column (40 beats with the shipped SUB_EVAL = 2),
// i.e. the PREVIOUS scan cycle's slice, which is what make/break detection
// compares against.  The new slice is injected into byte 0 at the end of the
// beat, dropping the consumed one.
//
// Scan calendar: three phases, counted in ENABLED beats, and
// 8 scan + 8 x (SUB_EVAL + 1) analyse + 8 advance = 32 + 8 x SUB_EVAL rotations per
// cycle, always a multiple of 8, so head is column 0 again at the start of every
// scan.  With the shipped SUB_EVAL = 2 one cycle is 40 beats.
//
//   P_SCAN (8 beats, ap = 0..PASS_WRAP, one per column).  head = ap = the column
//   being driven.  old = byte 7, rin = row_in ^ ROW_POL:
//     press8 = rin & ~old      keys closed since the previous cycle
//     rel8   = old & ~rin      keys opened since the previous cycle
//     rin == STUCK_PAT                       -> stuck_seen = 1 (column shorted)
//     press8 != 0 -> press_col = 1, press_code = CODE_BASE + {head, lsb(press8)},
//                    press_cnt + 1
//     rel8   != 0 -> rel_col   = 1, rel_code   = CODE_BASE + {head, lsb(rel8)},
//                    rel_cnt + 1
//   ring <= {ring[55:0], rin} (inject), tok rotates, and the analyser is primed
//   for the first pass: tgt <= byte 6, tgtc <= enc3(rotated tok), orv <= 0.
//   ap == PASS_WRAP ends the phase.
//
//   P_ANALZ (8 passes x (SUB_EVAL + 1) beats, i.e. 24 beats for the shipped
//   SUB_EVAL = 2; pass counter ap, beat counter sub).
//   Ghost rule, exactly the phantom-corner definition: a corner (r, c) that is not
//   closed is a phantom when some other column c1 shares a closed row with c and
//   is itself closed in row r:
//     ph(c) = ( OR over all c1 with (slice(c1) & slice(c)) != 0 of slice(c1) )
//             & ~slice(c)
//   The target column is registered once per pass (tgt, taken from byte 6 one beat
//   earlier, which is that pass's head).  Bytes {1,3,5,7} are compared against tgt
//   on the SUB_EVAL comparison beats of a pass (sub < SUB_EVAL); because the ring
//   advances one slot per beat those first two beats cover the relative columns
//   {6,4,2,0} and {7,5,3,1} of the target, i.e. all seven other columns plus the
//   self term, which is harmless because the final mask removes slice(c) again.
//   A union is idempotent, so any further comparison beat only repeats columns it
//   has already contributed and cannot change ph:
//     en_i = ((byte_i & tgt) != 0),  orv_u = OR over i of (byte_i & {8{en_i}})
//     sub == 0: orv <= orv_u             (orv was cleared)
//     0 < sub < SUB_EVAL: orv <= orv | orv_u
//     sub == SUB_EVAL: ph_nx = orv & ~tgt is the complete union of THIS pass.  Its
//       first phantom row latches ghost_seen and ph_idx = {tgtc, lsb(ph_nx)} if no
//       phantom had been found yet in this cycle; tgt/tgtc/orv reload and sub <= 0.
//   Every beat rotates the ring and tok.  On the last beat of the last pass
//   (sub == SUB_EVAL, ap == PASS_WRAP) the head is column 7, because the phase is
//   8 x (SUB_EVAL + 1) beats long, a multiple of 8, so byte 6 carries column 0:
//   that beat hands the calendar to P_EMIT with rem <= byte 6, ew <= 0,
//   slot_n <= 0, key_count <= 0 and
//   it publishes what the analyser found for THIS matrix before any code is
//   emitted, so ghost_flag / phantom_code / stuck_flag always describe the report
//   that is being walked:
//     ghost_flag   = ghost_seen | (ph_nx != 0),
//     phantom_code = that flag ? CODE_BASE + (ghost_seen ? ph_idx
//                                              : {tgtc, lsb(ph_nx)}) : NO_CODE,
//     stuck_flag   = stuck_seen,  and ghost_seen / stuck_seen then clear.
//
//   P_EMIT (key_count + 8 beats).  N-key roll-over capture: the walk reports EVERY
//   closure of the freshly captured matrix, lowest column first (rem is loaded from
//   column 0 and the ring then advances column by column) and lowest row first
//   inside a column.  While rem != 0 one code beat per set bit, no rotation:
//     code_valid = 1, key_code = CODE_BASE + {enc3(tok), lsb(rem)},
//     code_slot = slot_n, slot_n + 1, key_count + 1, rem <= rem & ~onehot
//   (onehot = rem & -rem, the lowest set bit; lsb(rem) = enc3(onehot)).
//   When rem == 0 the walk rotates to the next column (rem <= byte 6, ew + 1), and
//   on the beat where rem == 0 and ew == EMIT_WRAP the eighth rotation happens and
//   the report is published:
//     report_done = 1, scan_cnt + 1, nk_over = (key_count > NKR_MAX),
//     press_cnt / rel_cnt / press_code / rel_code cleared.  key_count keeps the
//     published total until the next hand-over clears it.
//   Phantom codes are NEVER emitted: the walk only visits ring, and a phantom
//   corner is by construction a bit that is not set in ring.  The predicted
//   phantom is reported separately on phantom_code with ghost_flag.
//
// Codes.  A key at (row r, column c) codes as CODE_BASE + (c * 8 + r), so the 64
// positions occupy one contiguous 64-code block.  NO_CODE is the idle value on
// every beat that does not carry a code.
//
// Lock-up.  ap, sub and ew are bounded by explicit wrap comparisons and the
// unknown phase encoding returns to P_SCAN, so no state can hang.
module ips_kbd_matrix_scan #(
    parameter [7:0] CODE_BASE = 8'h21,
    parameter [3:0] NKR_MAX   = 4'd6,
    parameter [7:0] ROW_POL   = 8'h00
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  row_in,
    output wire [7:0]  col_drv,
    output wire [3:0]  scan_col,
    output reg  [1:0]  phase,
    output reg  [7:0]  key_code,
    output reg         code_valid,
    output reg  [6:0]  code_slot,
    output reg  [6:0]  key_count,
    output reg         press_col,
    output reg         rel_col,
    output reg  [7:0]  press_code,
    output reg  [7:0]  rel_code,
    output reg  [5:0]  press_cnt,
    output reg  [5:0]  rel_cnt,
    output reg         ghost_flag,
    output reg  [7:0]  phantom_code,
    output reg         nk_over,
    output reg         stuck_flag,
    output reg         report_done,
    output reg  [7:0]  scan_cnt
);

localparam [2:0] PASS_WRAP = 3'd7;
localparam [7:0] STUCK_PAT = 8'hFF;
localparam [1:0] SUB_EVAL  = 2'd2;
localparam [7:0] NO_CODE   = 8'h00;
localparam [2:0] EMIT_WRAP = 3'd7;
localparam [1:0] P_SCAN    = 2'd0;
localparam [1:0] P_ANALZ   = 2'd1;
localparam [1:0] P_EMIT    = 2'd2;

reg [63:0] ring;
reg [7:0]  tok;
reg [2:0]  ap;
reg [1:0]  sub;
reg [2:0]  ew;
reg [7:0]  tgt;
reg [2:0]  tgtc;
reg [7:0]  orv;
reg [7:0]  rem;
reg        ghost_seen;
reg        stuck_seen;
reg [5:0]  ph_idx;
reg [6:0]  slot_n;

// Fixed ring reads.  The analyser only ever needs the four comparison slots
// {1,3,5,7}, the next head (byte 6) and the current head (byte 7).
wire [7:0] B1 = ring[15:8];
wire [7:0] B3 = ring[31:24];
wire [7:0] B5 = ring[47:40];
wire [7:0] B6 = ring[55:48];
wire [7:0] B7 = ring[63:56];

// Index of a one-hot byte: three OR trees, one per index bit.
function [2:0] enc3;
    input [7:0] oh;
    begin
        enc3 = {(oh[4] | oh[5] | oh[6] | oh[7]),
                (oh[2] | oh[3] | oh[6] | oh[7]),
                (oh[1] | oh[3] | oh[5] | oh[7])};
    end
endfunction

// Lowest set bit index of a byte (callers gate on a non-zero byte; a zero byte
// returns row 0, which is never used as a code).
function [2:0] lsb3;
    input [7:0] v;
    reg [2:0] k;
    begin
        k = 3'd0;
        if (v[7])                 k = 3'd7;
        if (v[6])                 k = 3'd6;
        if (v[5])                 k = 3'd5;
        if (v[4])                 k = 3'd4;
        if (v[3])                 k = 3'd3;
        if (v[2])                 k = 3'd2;
        if (v[1])                 k = 3'd1;
        if (v[0])                 k = 3'd0;
        lsb3 = k;
    end
endfunction

wire [2:0] head = enc3(tok);
wire [7:0] rin  = row_in ^ ROW_POL;
wire [7:0] inject = (phase == P_SCAN) ? rin : B7;
wire [63:0] ring_nx = {ring[55:0], inject};
wire [7:0]  tok_nx  = {tok[6:0], tok[7]};

// Analyser: four comparisons of fixed slots against the registered target.
wire       e1   = ((B1 & tgt) != 8'h00);
wire       e3   = ((B3 & tgt) != 8'h00);
wire       e5   = ((B5 & tgt) != 8'h00);
wire       e7   = ((B7 & tgt) != 8'h00);
wire [7:0] uu   = (B1 & {8{e1}}) | (B3 & {8{e3}})
                 | (B5 & {8{e5}}) | (B7 & {8{e7}});
wire [7:0] orv_nx = orv | uu;
wire [7:0] ph_nx  = orv & ~tgt;
wire       ghost_nx = ghost_seen | (ph_nx != 8'h00);
wire [5:0] ph_idx_nx = ghost_seen ? ph_idx : {tgtc, lsb3(ph_nx)};

wire [7:0] press8 = rin & ~B7;
wire [7:0] rel8   = B7 & ~rin;

wire [7:0] onehot = rem & ((~rem) + 8'd1);
wire [2:0] rls    = enc3(onehot);
wire [5:0] eidx   = {head, rls};

assign col_drv  = tok;
assign scan_col = {1'b0, head};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase        <= P_SCAN;
        ring         <= 64'h0000000000000000;
        tok          <= 8'h01;
        ap           <= 3'd0;
        sub          <= 2'd0;
        ew           <= 3'd0;
        tgt          <= 8'h00;
        tgtc         <= 3'd0;
        orv          <= 8'h00;
        rem          <= 8'h00;
        key_code     <= NO_CODE;
        code_valid   <= 1'b0;
        code_slot    <= 7'd0;
        slot_n       <= 7'd0;
        key_count    <= 7'd0;
        press_col    <= 1'b0;
        rel_col      <= 1'b0;
        press_code   <= NO_CODE;
        rel_code     <= NO_CODE;
        press_cnt    <= 6'd0;
        rel_cnt      <= 6'd0;
        ghost_seen   <= 1'b0;
        stuck_seen   <= 1'b0;
        ph_idx       <= 6'd0;
        ghost_flag   <= 1'b0;
        phantom_code <= NO_CODE;
        nk_over      <= 1'b0;
        stuck_flag   <= 1'b0;
        report_done  <= 1'b0;
        scan_cnt     <= 8'h00;
    end else if (clk_en) begin
        report_done <= 1'b0;
        code_valid  <= 1'b0;
        key_code    <= NO_CODE;
        press_col   <= 1'b0;
        rel_col     <= 1'b0;
        case (phase)
            P_SCAN: begin
                ring <= ring_nx;
                tok  <= tok_nx;
                tgt  <= B6;
                tgtc <= enc3(tok_nx);
                orv  <= 8'h00;
                if (rin == STUCK_PAT) begin
                    stuck_seen <= 1'b1;
                end
                if (press8 != 8'h00) begin
                    press_col  <= 1'b1;
                    press_code <= CODE_BASE + {5'd0, head, lsb3(press8)};
                    press_cnt  <= press_cnt + 6'd1;
                end
                if (rel8 != 8'h00) begin
                    rel_col    <= 1'b1;
                    rel_code   <= CODE_BASE + {5'd0, head, lsb3(rel8)};
                    rel_cnt    <= rel_cnt + 6'd1;
                end
                if (ap == PASS_WRAP) begin
                    ap    <= 3'd0;
                    sub   <= 2'd0;
                    phase <= P_ANALZ;
                end else begin
                    ap <= ap + 3'd1;
                end
            end
            P_ANALZ: begin
                ring <= ring_nx;
                tok  <= tok_nx;
                if (sub < SUB_EVAL) begin
                    if (sub == 2'd0) begin
                        orv <= uu;
                    end else begin
                        orv <= orv_nx;
                    end
                    sub <= sub + 2'd1;
                end else begin
                    if ((ph_nx != 8'h00) && (ghost_seen == 1'b0)) begin
                        ghost_seen <= 1'b1;
                        ph_idx     <= {tgtc, lsb3(ph_nx)};
                    end
                    tgt  <= B6;
                    tgtc <= enc3(tok_nx);
                    orv  <= 8'h00;
                    sub  <= 2'd0;
                    if (ap == PASS_WRAP) begin
                        ap           <= 3'd0;
                        phase        <= P_EMIT;
                        rem          <= B6;
                        ew           <= 3'd0;
                        slot_n       <= 7'd0;
                        key_count    <= 7'd0;
                        ghost_flag   <= ghost_nx;
                        phantom_code <= ghost_nx
                                     ? (CODE_BASE + {2'd0, ph_idx_nx}) : NO_CODE;
                        stuck_flag   <= stuck_seen;
                        ghost_seen   <= 1'b0;
                        stuck_seen   <= 1'b0;
                    end else begin
                        ap <= ap + 3'd1;
                    end
                end
            end
            P_EMIT: begin
                if (rem != 8'h00) begin
                    code_valid <= 1'b1;
                    key_code   <= CODE_BASE + {2'd0, eidx};
                    code_slot  <= slot_n;
                    slot_n     <= slot_n + 7'd1;
                    key_count  <= key_count + 7'd1;
                    rem        <= rem & ~onehot;
                end else begin
                    ring <= ring_nx;
                    tok  <= tok_nx;
                    rem  <= B6;
                    if (ew == EMIT_WRAP) begin
                        phase        <= P_SCAN;
                        ew           <= 3'd0;
                        report_done  <= 1'b1;
                        nk_over      <= (key_count > {3'd0, NKR_MAX});
                        scan_cnt     <= scan_cnt + 8'd1;
                        press_cnt    <= 6'd0;
                        rel_cnt      <= 6'd0;
                        press_code   <= NO_CODE;
                        rel_code     <= NO_CODE;
                    end else begin
                        ew <= ew + 3'd1;
                    end
                end
            end
            default: begin
                phase <= P_SCAN;
                ap    <= 3'd0;
                sub   <= 2'd0;
            end
        endcase
    end
end

endmodule
