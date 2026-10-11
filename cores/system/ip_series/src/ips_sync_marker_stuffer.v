`timescale 1ns / 1ps
// ips_sync_marker_stuffer : byte-oriented sync marker inserter / remover with
// escape (stuffing) transparency, per the pkt-series contract "inserts and removes a
// byte-oriented sync marker with escape/unescape transparency".
//
// One core, two directions, selected by the mode input:
//   mode = 0  INSERT  (stuffer / encoder)
//   mode = 1  REMOVE  (destuffer / decoder)
//
// Transparency rules (the same control bytes both ways, so a stuffed stream is
// reversible):
//   * SYNC_BYTE (default 8'h7A) is the frame marker; ESC_BYTE (8'h7D) is the escape
//     and an escaped byte is transmitted as ESC_BYTE followed by (byte ^ XOR_MASK)
//     with XOR_MASK = 8'h20, so a payload byte that happens to look like a control
//     byte never reaches the receiver as a control byte;
//   * a data byte equal to SYNC_BYTE or ESC_BYTE is inserted as the two-byte escape
//     sequence; any other data byte is forwarded untouched;
//   * sync_req is a framing request presented on a beat of its own (in_valid low):
//     the marker is then emitted as one output byte with out_sof set.  Presenting
//     sync_req together with a data byte is a requester error: it is latched and
//     counted (the data byte is still forwarded, so nothing is corrupted silently);
//   * the remover recognises SYNC_BYTE as a frame boundary (re-emitted with out_sof
//     so the downstream keeps the same sync event), consumes ESC_BYTE and unfolds the
//     byte behind it.  An escape that is still pending when a marker arrives is a
//     truncated escape, two escapes in a row are ambiguous, and an escaped byte that
//     unfolds into a value the stuffer could never have escaped (i.e. not a control
//     byte) is an unverifiable escape: each one is latched in err_sticky and counted
//     in cnt_spur, never dropped silently.  A legal escape of SYNC_BYTE or ESC_BYTE
//     is transparent and is never reported.
//
// Handshake: FWFT output queue of Q_DEPTH slots.  out_valid is the queue being
// non-empty, out_byte / out_sof are its head and hold steady while out_ready is low
// (the head only moves on an accepted output beat).  in_ready reflects the room the
// beat would need, so an escaping byte needs two free slots and a refused byte is
// simply presented again by the requester; no accepted byte is ever dropped.
//
// Accounting (explicit and sticky, per the series measurement contract): cnt_in
// counts consumed data bytes, cnt_out emitted output bytes, cnt_sync markers
// inserted or recognised, cnt_esc escapes inserted or consumed, cnt_spur the
// malformed events above and frame_esc the escapes of the frame being streamed (it is
// cleared by a marker and clamps at FRAME_ESC_MAX instead of wrapping, latching
// err_sticky[3] when a frame needs more escapes than its budget).  Every counter
// saturates at its own ceiling and latches its cnt_sat bit, so saturation is reported
// rather than wrapping silently; queue_level exposes the live occupancy.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous reset
// (docs/IP_CORE_SOP.md trap T2).  Only compares, XOR with a constant mask and
// constant add/subtract are used, so there is no DSP and no arithmetic (trap T4).
module ips_sync_marker_stuffer #(
    parameter [7:0] SYNC_BYTE     = 8'h7A,
    parameter [7:0] ESC_BYTE      = 8'h7D,
    parameter [7:0] XOR_MASK      = 8'h20,
    parameter [7:0] FRAME_ESC_MAX = 8'd24
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        mode,        // low: insert marker and escape, high: remove them
    input  wire        in_valid,
    input  wire [7:0]  in_byte,
    input  wire        sync_req,    // marker request, presented on a beat of its own
    output wire        in_ready,

    output wire        out_valid,
    output wire        out_sof,
    output wire [7:0]  out_byte,
    input  wire        out_ready,

    output reg  [7:0]  cnt_in,
    output reg  [7:0]  cnt_out,
    output reg  [7:0]  cnt_esc,
    output reg  [7:0]  cnt_sync,
    output reg  [3:0]  cnt_spur,
    output wire [2:0]  queue_level,
    output reg  [7:0]  frame_esc,
    output reg  [3:0]  err_sticky,
    output reg  [4:0]  cnt_sat
);

// Output queue depth and the counter ceilings.  A counter that reaches its ceiling
// stops there and latches the matching cnt_sat bit.
localparam [2:0] Q_DEPTH = 3'd3;
localparam [7:0] LIM8    = 8'hFF;
localparam [3:0] LIM4    = 4'hF;

reg [7:0] s0, s1, s2;      // slot 0 is the queue head (first out)
reg       h0, h1, h2;      // its start-of-frame (marker) flags
reg [2:0] qcnt;
reg       esc_pend;
// acc: this beat's input is consumed, pop: this beat's output head is consumed
wire      acc;
wire      pop;
assign    pop = out_valid && out_ready;
// the queue occupancy is the state itself, exported for the measurement side
assign    queue_level = qcnt;

// ---------------- classification of the presented beat ---------------------------
wire enc         = ~mode;
wire ctl_look    = (in_byte == SYNC_BYTE) || (in_byte == ESC_BYTE);
wire need_esc    = enc && in_valid && ctl_look;
wire d_sync      = mode && in_valid && (in_byte == SYNC_BYTE);
wire d_esc       = mode && in_valid && (in_byte == ESC_BYTE);
wire d_unfold    = mode && esc_pend && in_valid && !d_sync && !d_esc;
// the stuffer only ever escapes a control byte, so an escaped byte whose unfolded
// value is NOT a control byte could not have been produced by the encoder: it is an
// unverifiable escape.  (The legal escapes of SYNC_BYTE and ESC_BYTE unfold back into
// exactly those two control bytes, so they must never be flagged: transparency
// requires a marker-valued payload byte to round-trip.)
wire unfold_bad  = d_unfold && !(((in_byte ^ XOR_MASK) == SYNC_BYTE)
                              || ((in_byte ^ XOR_MASK) == ESC_BYTE));
wire marker_out  = enc && sync_req && !in_valid;   // marker beat accepted by the core
wire ev_malformed = in_valid && sync_req;
// a marker landing on a half-finished escape is the truncated-escape error
wire ev_trunc    = d_sync && esc_pend;
wire ev_ambig    = d_esc && esc_pend;
wire ev_esc_ins  = need_esc;                       // one ESC byte inserted
wire ev_esc_rm   = d_unfold;                       // one ESC byte consumed
wire ev_esc      = ev_esc_ins || ev_esc_rm;
wire ev_sync     = marker_out || d_sync;

// ---------------- push list: 0..3 bytes appended to the queue --------------------
reg [2:0] ins;
reg [7:0] p0, p1, p2;
reg       g0, g1, g2;

always @(*) begin
    ins = 3'd0;
    p0  = 8'h00;
    p1  = 8'h00;
    p2  = 8'h00;
    g0  = 1'b0;
    g1  = 1'b0;
    g2  = 1'b0;
    if (enc) begin
        if (in_valid) begin
            if (need_esc) begin
                ins = 3'd2;
                p0  = ESC_BYTE;
                p1  = in_byte ^ XOR_MASK;
            end else begin
                ins = 3'd1;
                p0  = in_byte;
            end
        end else if (sync_req) begin
            ins = 3'd1;
            p0  = SYNC_BYTE;
            g0  = 1'b1;
        end
    end else begin
        if (d_sync) begin
            ins = 3'd1;
            p0  = SYNC_BYTE;
            g0  = 1'b1;
        end else if (in_valid && !d_esc) begin
            ins = 3'd1;
            p0  = d_unfold ? (in_byte ^ XOR_MASK) : in_byte;
        end
    end
end

// the beat needs `ins` free slots; a refused beat is simply presented again
wire [2:0] room = Q_DEPTH - qcnt;
assign in_ready  = (room >= ins);
assign acc       = in_ready && (in_valid || (sync_req && enc));
assign out_valid = (qcnt != 3'd0);
assign out_byte  = s0;
assign out_sof   = h0;

// ---------------- shift-for-pop then insert the push list -----------------------
reg [7:0] n0, n1, n2;
reg       f0, f1, f2;
reg [2:0] base, nc;
reg [2:0] push;         // only an accepted beat appends anything

always @(*) begin
    base = pop ? (qcnt - 3'd1) : qcnt;
    push = acc ? ins : 3'd0;
    nc   = base + push;
    if (nc > Q_DEPTH) begin
        nc = Q_DEPTH;
    end
    n0  = pop ? s1 : s0;
    n1  = pop ? s2 : s1;
    n2  = s2;
    f0  = pop ? h1 : h0;
    f1  = pop ? h2 : h1;
    f2  = h2;
    if ((push >= 3'd1) && (base < Q_DEPTH)) begin
        case (base)
            3'd0:    begin n0 = p0; f0 = g0; end
            3'd1:    begin n1 = p0; f1 = g0; end
            default: begin n2 = p0; f2 = g0; end
        endcase
    end
    if (push >= 3'd2) begin
        case (base)
            3'd0: begin n1 = p1; f1 = g1; end
            3'd1: begin n2 = p1; f2 = g1; end
            default: begin end
        endcase
    end
    if (push >= 3'd3) begin
        case (base)
            3'd0:    begin n2 = p2; f2 = g2; end
            default: begin end
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s0         <= 8'h00;
        s1         <= 8'h00;
        s2         <= 8'h00;
        h0         <= 1'b0;
        h1         <= 1'b0;
        h2         <= 1'b0;
        qcnt       <= 3'd0;
        esc_pend   <= 1'b0;
        cnt_in     <= 8'h00;
        cnt_out    <= 8'h00;
        cnt_esc    <= 8'h00;
        cnt_sync   <= 8'h00;
        cnt_spur   <= 4'h0;
        frame_esc  <= 8'h00;
        err_sticky <= 4'h0;
        cnt_sat    <= 5'b00000;
    end else if (clk_en) begin
        s0 <= n0;
        s1 <= n1;
        s2 <= n2;
        h0 <= f0;
        h1 <= f1;
        h2 <= f2;
        qcnt <= nc;

        if (acc) begin
            if (ev_trunc || ev_ambig || unfold_bad || ev_malformed) begin
                if (cnt_spur < LIM4) begin
                    cnt_spur <= cnt_spur + 4'h1;
                end else begin
                    cnt_sat[4] <= 1'b1;
                end
            end
            if (ev_trunc)   err_sticky[0] <= 1'b1;
            if (ev_ambig || unfold_bad) err_sticky[1] <= 1'b1;
            if (ev_malformed) err_sticky[2] <= 1'b1;
            if (in_valid) begin
                if (cnt_in < LIM8) begin
                    cnt_in <= cnt_in + 8'h01;
                end else begin
                    cnt_sat[0] <= 1'b1;
                end
            end
            if (ev_sync) begin
                if (cnt_sync < LIM8) begin
                    cnt_sync <= cnt_sync + 8'h01;
                end else begin
                    cnt_sat[3] <= 1'b1;
                end
            end
            if (ev_esc) begin
                if (cnt_esc < LIM8) begin
                    cnt_esc <= cnt_esc + 8'h01;
                end else begin
                    cnt_sat[2] <= 1'b1;
                end
            end
            // escapes of the frame being streamed: clamps and reports, never wraps
            if (ev_sync) begin
                frame_esc <= 8'h00;
            end else if (ev_esc) begin
                if (frame_esc >= FRAME_ESC_MAX) begin
                    err_sticky[3] <= 1'b1;
                    frame_esc <= FRAME_ESC_MAX;
                end else begin
                    frame_esc <= frame_esc + 8'h01;
                end
            end
            // a consumed escape is only outstanding until its byte arrives; a marker
            // cancels it (truncated escape, reported above)
            esc_pend <= d_esc ? 1'b1 : (d_unfold ? 1'b0 : (d_sync ? 1'b0 : esc_pend));
        end
        if (pop) begin
            if (cnt_out < LIM8) begin
                cnt_out <= cnt_out + 8'h01;
            end else begin
                cnt_sat[1] <= 1'b1;
            end
        end
    end
end

endmodule
