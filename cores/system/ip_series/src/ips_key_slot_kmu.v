`timescale 1ns / 1ps
// ips_key_slot_kmu : key-management-unit style slot block.  SLOTS slots each hold
// one WORD_BITS key word loaded in a single beat.  Every slot is write-once,
// carries the privilege tag bound at load time, and is locked after loading; a
// slot only unlocks when the caller presents the slot-derived attestation word
// (key ^ (KEY_SALT ^ slot)) AND the matching tag.  A failed unlock zeroises the
// slot and poisons it.  A denied read drives no key material and bumps the sticky
// per-slot tamper bit plus the saturating global tamper counter; clr_req purges a
// slot so it can be loaded again.  Two operations in one beat are rejected.
// FUNCTIONAL PROTOTYPE ONLY: slot policy logic only -- constant-time and
// side-channel leakage behaviour is NOT verified here and board evidence is
// DEFERRED.
//
// Slot selection is a one-hot decode plus constant-width slices only (no variable
// base window), so nothing here infers a multiplier or a barrel shifter and no DSP
// is used (docs/IP_CORE_SOP.md traps T3 and T4).  The default geometry -- 8 slots of
// one 16-bit key word each -- is what fits the series LUT budget; SLOTS/WORD_BITS are
// parameters, so a wider slot file costs LUTs linearly.
module ips_key_slot_kmu #(
    parameter SLOTS     = 8,
    parameter WORD_BITS = 16,
    parameter KEY_SALT  = 16'hA534
)(
    input  wire                     clk,
    input  wire                     clk_en,
    input  wire                     rst_n,

    input  wire                     ld_valid,
    input  wire                     lock_req,
    input  wire                     unlock_req,
    input  wire                     rd_req,
    input  wire                     clr_req,
    input  wire [$clog2(SLOTS)-1:0] slot,

    input  wire  [WORD_BITS-1:0]    ld_data,
    input  wire  [WORD_BITS-1:0]    attestation,
    input  wire  [3:0]              ld_priv,
    input  wire  [3:0]              att_priv,
    input  wire  [3:0]              rd_priv,

    output reg [WORD_BITS-1:0]      rd_data,
    output reg                      rd_valid,
    output reg                      rd_denied,
    output reg [SLOTS-1:0]          locked,
    output reg [SLOTS-1:0]          loaded,
    output reg [SLOTS-1:0]          poisoned,
    output reg [SLOTS-1:0]          slot_tamper,
    output reg [7:0]                tamper_cnt,
    output reg [2:0]                err_code,
    output reg                      err_any
);

localparam [7:0] TAMPER_MAX = 8'hFF;
localparam [2:0] ERR_ONCE   = 3'd1;
localparam [2:0] ERR_BUSY   = 3'd2;

localparam integer IDXW = $clog2(SLOTS);
localparam integer MEMW = SLOTS * WORD_BITS;

localparam [2:0] ERR_NONE  = 3'd0;
localparam [2:0] ERR_LOCK  = 3'd3;
localparam [2:0] ERR_PRIV  = 3'd5;
localparam [2:0] ERR_ATT   = 3'd6;
localparam [2:0] ERR_STATE = 3'd7;

reg [MEMW-1:0]    keymem;
reg [SLOTS*4-1:0] privmem;

integer r;
integer w;

// One-hot slot decode: every slice below is a constant window, so the whole block
// stays a plain register file with AND-OR read-out.
wire [SLOTS-1:0] slot_hit;
genvar g;
generate
    for (g = 0; g < SLOTS; g = g + 1) begin : G_DEC
        assign slot_hit[g] = (slot == g);
    end
endgenerate

reg [WORD_BITS-1:0] cur_key;
reg [3:0]           cur_priv;

always @(*) begin
    cur_key  = {WORD_BITS{1'b0}};
    cur_priv = 4'h0;
    for (r = 0; r < SLOTS; r = r + 1) begin
        cur_key  = cur_key  | ({WORD_BITS{slot_hit[r]}} & keymem[r*WORD_BITS +: WORD_BITS]);
        cur_priv = cur_priv | ({4{slot_hit[r]}} & privmem[r*4 +: 4]);
    end
end

wire slot_locked  = |(locked     & slot_hit);
wire slot_loaded  = |(loaded     & slot_hit);
wire slot_poisoned = |(poisoned  & slot_hit);
wire slot_state   = slot_locked | slot_poisoned;
wire slot_ready   = slot_loaded & ~slot_locked & ~slot_poisoned;

wire [2:0] op_count = {2'd0, ld_valid} + {2'd0, lock_req} + {2'd0, unlock_req} +
                      {2'd0, rd_req}    + {2'd0, clr_req};
wire op_multi = (op_count > 3'd1);
wire any_op   = ld_valid | lock_req | unlock_req | rd_req | clr_req;

wire ld_state_bad = ld_valid   & ~op_multi &  slot_state;
wire ld_once_bad  = ld_valid   & ~op_multi & ~slot_state & slot_loaded;
wire ld_fire      = ld_valid   & ~op_multi & ~slot_state & ~slot_loaded;
wire lk_fire      = lock_req   & ~op_multi &  slot_loaded;
wire lk_bad       = lock_req   & ~op_multi & ~slot_loaded;
wire un_state_bad = unlock_req & ~op_multi & ~(slot_loaded & slot_locked);

wire [WORD_BITS-1:0] salt_word   = KEY_SALT ^ {{(WORD_BITS-IDXW){1'b0}}, slot};
wire [WORD_BITS-1:0] att_expect  = cur_key ^ salt_word;
wire att_key_ok = (attestation == att_expect);
wire att_pri_ok = (att_priv == cur_priv);

wire un_ok  = unlock_req & ~op_multi & ~un_state_bad &  att_key_ok &  att_pri_ok;
wire un_bad = unlock_req & ~op_multi & ~un_state_bad & ~(att_key_ok & att_pri_ok);

wire rd_not_ready = rd_req & ~op_multi & ~slot_ready;
wire rd_pri_bad   = rd_req & ~op_multi &  slot_ready & (rd_priv != cur_priv);
wire rd_fire      = rd_req & ~op_multi &  slot_ready & (rd_priv == cur_priv);
wire rd_deny      = rd_not_ready | rd_pri_bad;

wire clr_fire = clr_req & ~op_multi;
wire purge_fire = un_bad | clr_fire;

wire tamper_evt = ld_state_bad | ld_once_bad | un_bad | rd_deny;
wire tamper_full = (tamper_cnt >= TAMPER_MAX);
wire bump = tamper_evt & ~tamper_full;

wire [SLOTS-1:0] set_loaded = slot_hit & {SLOTS{ld_fire}};
wire [SLOTS-1:0] clr_loaded = slot_hit & {SLOTS{(un_bad | clr_fire)}};
wire [SLOTS-1:0] set_locked = slot_hit & {SLOTS{(lk_fire | un_bad)}};
wire [SLOTS-1:0] clr_locked = slot_hit & {SLOTS{(un_ok | clr_fire)}};
wire [SLOTS-1:0] set_poison = slot_hit & {SLOTS{un_bad}};
wire [SLOTS-1:0] clr_poison = slot_hit & {SLOTS{clr_fire}};
wire [SLOTS-1:0] set_tamper = slot_hit & {SLOTS{tamper_evt}};

wire [2:0] nxt_err =
    op_multi    ? ERR_BUSY  :
    ld_valid    ? (ld_state_bad ? ERR_LOCK  :
                   ld_once_bad  ? ERR_ONCE  : ERR_NONE) :
    lock_req    ? (lk_bad      ? ERR_STATE : ERR_NONE) :
    unlock_req  ? (un_state_bad ? ERR_STATE :
                   un_ok        ? ERR_NONE :
                   att_pri_ok   ? ERR_ATT  : ERR_PRIV) :
    rd_req      ? (rd_not_ready ? ERR_LOCK :
                   rd_pri_bad   ? ERR_PRIV : ERR_NONE) :
    ERR_NONE;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_data     <= {WORD_BITS{1'b0}};
        rd_valid    <= 1'b0;
        rd_denied   <= 1'b0;
        locked      <= {SLOTS{1'b0}};
        loaded      <= {SLOTS{1'b0}};
        poisoned    <= {SLOTS{1'b0}};
        slot_tamper <= {SLOTS{1'b0}};
        tamper_cnt  <= 8'h00;
        err_code    <= ERR_NONE;
        err_any     <= 1'b0;
    end else if (clk_en) begin
        rd_valid  <= 1'b0;
        rd_denied <= 1'b0;

        if (rd_deny) rd_data <= {WORD_BITS{1'b0}};
        else if (rd_fire) rd_data <= cur_key;

        if (rd_fire) rd_valid <= 1'b1;
        else if (rd_deny) rd_denied <= 1'b1;

        if (any_op) err_code <= nxt_err;
        err_any <= err_any | (any_op & (nxt_err != ERR_NONE));

        loaded      <= (loaded  | set_loaded) & ~clr_loaded;
        locked      <= (locked  | set_locked) & ~clr_locked;
        poisoned    <= (poisoned | set_poison) & ~clr_poison;
        slot_tamper <=  slot_tamper | set_tamper;

        if (bump) tamper_cnt <= tamper_cnt + 8'h01;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        keymem  <= {MEMW{1'b0}};
        privmem <= {(SLOTS*4){1'b0}};
    end else if (clk_en) begin
        for (w = 0; w < SLOTS; w = w + 1) begin
            if (slot_hit[w]) begin
                if (purge_fire) begin
                    keymem[w*WORD_BITS +: WORD_BITS] <= {WORD_BITS{1'b0}};
                    if (un_bad) privmem[w*4 +: 4] <= 4'h0;
                end
                if (ld_fire) begin
                    keymem[w*WORD_BITS +: WORD_BITS] <= ld_data;
                    privmem[w*4 +: 4] <= ld_priv;
                end
            end
        end
    end
end

endmodule
