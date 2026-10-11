`timescale 1ns / 1ps
// tb_ips_key_slot_kmu : production-line testbench for the KMU-style slot block.
//
// ROUNDS scripted rounds walk every slot through the whole slot policy: purge, one
// write-once key-word load, an attempted rewrite of the loaded word (must be
// rejected with the write-once code and must NOT change the stored word), a load
// into a locked slot, a read while the slot is locked, an unlock attempt with the
// slot-derived attestation word and privilege tag (half of them deliberately wrong,
// so the zeroise-and-poison path runs), a read after the unlock and a read with a
// wrong tag.  Expectations come from the stimulus this bench drove, which is what
// proves that a locked slot never reads back its value and that a loaded word is
// really write-once.  Only DUT outputs are folded, plus a final configuration stamp
// read out of the DUT instance so the shipped parameter defaults are observable in
// the digest.  models/ips_key_slot_kmu.py computes the reference digest
// independently (docs/IP_CORE_SOP.md trap T1).
// Key words here are LCG-generated test-only patterns, not real keys.
module tb_ips_key_slot_kmu;

`include "ips_tb_common.vh"

localparam integer ROUNDS = 3;
localparam integer NSLOT  = 8;
localparam [31:0]  SEED    = 32'h1CEB00B0;
// Test-only copy of the slot salt: the bench must not read it out of the DUT,
// otherwise a wrong attestation could never be shown to be wrong.
localparam [15:0]  TB_SALT     = 16'hA534;
localparam [2:0]   TB_ERR_ONCE = 3'd1;
localparam [2:0]   TB_ERR_BUSY  = 3'd2;

reg                 rst_n;
reg                 clk_en;
reg                 ld_valid, lock_req, unlock_req, rd_req, clr_req;
reg  [2:0]          slot_drv;
reg  [15:0]         data_drv;
reg  [15:0]         att_drv;
reg  [3:0]          ldp_drv;
reg  [3:0]          attp_drv;
reg  [3:0]          rdp_drv;
reg  [31:0]         state;

wire [15:0]         rd_data;
wire                rd_valid;
wire                rd_denied;
wire [7:0]          locked;
wire [7:0]          loaded;
wire [7:0]          poisoned;
wire [7:0]          slot_tamper;
wire [7:0]          tamper_cnt;
wire [2:0]          err_code;
wire                err_any;

// No #() override: the bench exercises the declared default geometry, which is
// the configuration the manifest records and the mutation station checks.
ips_key_slot_kmu dut (
    .clk          (ips_clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .ld_valid     (ld_valid),
    .lock_req     (lock_req),
    .unlock_req   (unlock_req),
    .rd_req       (rd_req),
    .clr_req      (clr_req),
    .slot         (slot_drv),
    .ld_data      (data_drv),
    .attestation  (att_drv),
    .ld_priv      (ldp_drv),
    .att_priv     (attp_drv),
    .rd_priv      (rdp_drv),
    .rd_data      (rd_data),
    .rd_valid     (rd_valid),
    .rd_denied    (rd_denied),
    .locked       (locked),
    .loaded       (loaded),
    .poisoned     (poisoned),
    .slot_tamper  (slot_tamper),
    .tamper_cnt   (tamper_cnt),
    .err_code     (err_code),
    .err_any      (err_any)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer rnd;
integer sl;
integer pof;
integer keyok;
integer priok;
integer grant;
reg     bad;
reg     exp_deny;
reg     chk_once;
reg     chk_busy;
reg     obs_x;
reg [15:0] key_word;
reg [15:0] salt_word;
reg [7:0]  prev_tamper;
reg [7:0]  prev_slot_tamper;

function [31:0] next_state;
    input [31:0] s0;
    begin
        next_state = s0 * 32'd1664525 + 32'd1013904223;
    end
endfunction

// One logical beat: the requests are held for a single enabled clock, then the
// registered outputs are sampled one enabled clock after they were loaded.
task beat;
    input ldv;
    input lkv;
    input unv;
    input rdv;
    input clv;
    input [2:0]  slot;
    input [15:0] data;
    input [15:0] att;
    input [3:0]  ldp;
    input [3:0]  attp;
    input [3:0]  rdp;
    begin
        @(negedge ips_clk);
        ld_valid   = ldv;
        lock_req   = lkv;
        unlock_req = unv;
        rd_req     = rdv;
        clr_req    = clv;
        slot_drv   = slot;
        data_drv   = data;
        att_drv    = att;
        ldp_drv    = ldp;
        attp_drv   = attp;
        rdp_drv    = rdp;

        @(negedge ips_clk);
        ld_valid   = 1'b0;
        lock_req   = 1'b0;
        unlock_req = 1'b0;
        rd_req     = 1'b0;
        clr_req    = 1'b0;

        obs_x = (^{rd_data, rd_valid, rd_denied, locked, loaded, poisoned,
                   slot_tamper, tamper_cnt, err_code, err_any}) === 1'bx;
        if (obs_x) bad = 1'b1;

        // A denied read must never leave key material on the read bus.
        if (rd_denied === 1'b1 && rd_data !== 16'd0) bad = 1'b1;

        // Grant/deny expectation from this bench's own script.  The locked-slot
        // read (exp_deny) is the "a locked slot never reads back its value" test.
        if (rdv === 1'b1 && chk_busy === 1'b0) begin
            if (exp_deny === 1'b1) begin
                if (rd_denied !== 1'b1) bad = 1'b1;
                if (rd_valid  !== 1'b0) bad = 1'b1;
            end else begin
                if (rd_valid !== 1'b1)    bad = 1'b1;
                if (rd_denied !== 1'b0)   bad = 1'b1;
                if (rd_data !== key_word) bad = 1'b1;
            end
        end
        if (chk_once === 1'b1 && err_code !== TB_ERR_ONCE) bad = 1'b1;
        if (chk_busy === 1'b1 && err_code !== TB_ERR_BUSY) bad = 1'b1;

        // Saturating global counter, never decreasing; sticky per-slot tamper bits.
        if (tamper_cnt < prev_tamper) bad = 1'b1;
        if ((slot_tamper & prev_slot_tamper) !== prev_slot_tamper) bad = 1'b1;

        prev_tamper      = tamper_cnt;
        prev_slot_tamper = slot_tamper;
        chk_once         = 1'b0;
        chk_busy         = 1'b0;

        ips_fnv_word({16'd0, rd_data});
        ips_fnv_word({24'd0, tamper_cnt});
        ips_fnv_word({24'd0, locked});
        ips_fnv_word({24'd0, loaded});
        ips_fnv_word({24'd0, poisoned});
        ips_fnv_word({24'd0, slot_tamper});
        ips_fnv_word({29'd0, err_code});
        ips_fnv_word({30'd0, rd_valid, rd_denied});
        ips_fnv_word({31'd0, err_any});
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n            = 1'b0;
    clk_en           = 1'b0;
    ld_valid         = 1'b0;
    lock_req         = 1'b0;
    unlock_req       = 1'b0;
    rd_req           = 1'b0;
    clr_req          = 1'b0;
    slot_drv         = 3'd0;
    data_drv         = 16'd0;
    att_drv          = 16'd0;
    ldp_drv          = 4'd0;
    attp_drv         = 4'd0;
    rdp_drv          = 4'd0;
    state            = SEED;
    bad              = 1'b0;
    exp_deny         = 1'b0;
    chk_once         = 1'b0;
    chk_busy         = 1'b0;
    obs_x            = 1'b0;
    key_word         = 16'd0;
    salt_word        = 16'd0;
    prev_tamper      = 8'd0;
    prev_slot_tamper = 8'd0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (rnd = 0; rnd < ROUNDS; rnd = rnd + 1) begin
        for (sl = 0; sl < NSLOT; sl = sl + 1) begin
            pof   = (rnd ^ sl) & 32'hF;
            keyok = (((rnd + sl) & 32'h1) == 0) ? 1 : 0;
            priok = (((rnd + sl) & 32'h2) == 0) ? 1 : 0;

            state    = next_state(state);
            key_word = state[15:0] ^ 16'hA55A ^ (rnd * 8 + sl);
            salt_word = TB_SALT ^ {13'd0, sl[2:0]};

            // purge so every round starts the slot from the same state
            beat(1'b0, 1'b0, 1'b0, 1'b0, 1'b1, sl[2:0], 16'd0, 16'd0,
                 pof[3:0], pof[3:0], pof[3:0]);

            // write-once load of the slot's key word
            beat(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, sl[2:0], key_word, 16'd0,
                 pof[3:0], pof[3:0], pof[3:0]);

            // attempted rewrite of the loaded word: rejected, word kept
            chk_once = 1'b1;
            beat(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, sl[2:0], key_word ^ 16'h00F5, 16'd0,
                 pof[3:0], pof[3:0], pof[3:0]);

            // a malformed beat that asks for two operations at once
            if (sl == 3) begin
                chk_busy = 1'b1;
                beat(1'b1, 1'b0, 1'b0, 1'b1, 1'b0, sl[2:0], key_word, 16'd0,
                     pof[3:0], pof[3:0], pof[3:0]);
            end

            // lock the slot
            beat(1'b0, 1'b1, 1'b0, 1'b0, 1'b0, sl[2:0], 16'd0, 16'd0,
                 pof[3:0], pof[3:0], pof[3:0]);

            // load into a locked slot: rejected, stored word still untouched
            beat(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, sl[2:0], key_word ^ 16'h5A00, 16'd0,
                 pof[3:0], pof[3:0], pof[3:0]);

            // THE test: a locked slot must never read back its value
            exp_deny = 1'b1;
            beat(1'b0, 1'b0, 1'b0, 1'b1, 1'b0, sl[2:0], 16'd0, 16'd0,
                 pof[3:0], pof[3:0], pof[3:0]);

            // unlock with the slot-derived attestation, or a wrong one
            att_drv = key_word ^ salt_word;
            if (keyok == 0) att_drv = att_drv ^ 16'h0001;
            attp_drv = priok ? pof[3:0] : (pof[3:0] ^ 4'h7);
            beat(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, sl[2:0], 16'd0, att_drv,
                 pof[3:0], attp_drv, pof[3:0]);

            // read after the unlock: granted only if the unlock really succeeded
            grant    = (keyok == 1 && priok == 1) ? 1 : 0;
            exp_deny = grant ? 1'b0 : 1'b1;
            beat(1'b0, 1'b0, 1'b0, 1'b1, 1'b0, sl[2:0], 16'd0, 16'd0,
                 pof[3:0], pof[3:0], pof[3:0]);

            // unlock an already unlocked / already poisoned slot: rejected
            beat(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, sl[2:0], 16'd0, key_word ^ salt_word,
                 pof[3:0], pof[3:0], pof[3:0]);

            // read with a wrong privilege tag: rejected
            exp_deny = 1'b1;
            beat(1'b0, 1'b0, 1'b0, 1'b1, 1'b0, sl[2:0], 16'd0, 16'd0,
                 pof[3:0], pof[3:0], pof[3:0] ^ 4'h5);
            exp_deny = 1'b0;
        end
    end

    // idle beat: the read pulses must fall, the state registers must hold
    beat(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 3'd0, 16'd0, 16'd0, 4'd0, 4'd0, 4'd0);
    if (rd_valid === 1'b1 || rd_denied === 1'b1) bad = 1'b1;

    ips_fnv_word(ROUNDS);
    ips_fnv_word(NSLOT);
    ips_fnv_word(dut.SLOTS);
    ips_fnv_word(dut.WORD_BITS);

    ips_verdict(!bad, "ips_key_slot_kmu");
end

endmodule
