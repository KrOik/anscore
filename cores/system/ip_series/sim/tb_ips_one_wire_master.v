`timescale 1ns / 1ps
// tb_ips_one_wire_master : production-line testbench for the 1-Wire master.
//
// Slave model, timing base, fold rule (the same contract is stated at the top of
// models/ips_one_wire_master.py; both are written from this spec and never from
// simulation output -- docs/IP_CORE_SOP.md trap T1):
//
// Timeline.  The plan is a list of entries; an entry is one command.  Beat 0 of an
// entry presents cmd_valid with the command; the following beats are the phase
// ticks and the phase tick index p is the master's own tc (p = 0 is tc = 0).  A
// reset entry is 1 + PRE_END_TB beats long, a byte entry is 1 + SLOT*BITS beats.
// Gap beats (tick held low) and stall beats (clk_en held low) are appended inside
// an entry at a fixed phase index; they do not advance the master, so the
// tick-domain plan stays aligned whatever the beat pattern does in between.
//
// Slave (open drain, pin = ~(master pull-down OR slave pull-down)):
//   * presence: the slave pulls low for phase ticks PRE_ON..PRE_OFF of a reset
//     entry when that entry asks for a presence response, and never pulls for the
//     no-presence entries -- the error path the core must flag.
//   * read slots: slot j (LSB first) carries bit j of the byte the slave returns.
//     A 0 bit is signalled by pulling low, a 1 bit by leaving go.  M_WIDE holds the
//     low for SLV_ON..SLV_OFF, M_NARROW only for the single tick SLV_ON (the
//     marginal slave that pins down the sample instant), M_DEAD never answers, so
//     every slot samples a released line.  The suite therefore samples slots at
//     both levels.
//   * write slots: the slave is silent, the pad just follows the master.
//
// Scratchpad blocks.  Two 9-byte read blocks with crc_en on every byte and crc_end
// on the 9th: the first carries PD plus the DS28EC01 CRC byte CRCB (Maxim residue
// 8'h00, so it must be judged good), the second is the same block with bit 3 of
// PD[4] corrupted on the wire, which must raise the CRC error flag.  A short
// 4-byte crc_en block closed by crc_end must raise the block-length flag.
//
// Fold rule, identical in the model: every beat folds three words, in this order,
// using the values observed after that beat's enabled clock edge:
//   w1 = {18'd0, tc, bit_idx, state, ow_oe, done}
//   w2 = {8'd0,  rx_word, tx_word, byte_count}
//   w3 = {14'd0, nopre_sticky, crc_sticky, len_sticky, busy_sticky, bad_cmd_sticky,
//         presence, rst_count, crc_count, err_count}
// and on every beat whose done is high (done is held while tick or clk_en is low)
// one extra word {24'd0, crc} is folded.  After the plan, nbeats and one summary
// word {17'd0, state[2:0], rst_count, crc_count, err_count} are folded.
//
// Observed only with === / !== so an unknown can never look like a pass (trap T6).
module tb_ips_one_wire_master;

`include "ips_tb_common.vh"

localparam integer MAXB       = 4096;
localparam integer SLOT       = 6;          // entry phase ticks per slot
localparam integer BITS       = 8;
localparam integer PRE_END_TB = 12;         // reset entry phase ticks 0..12
localparam integer PRE_ON     = 7;          // presence pulse window
localparam integer PRE_OFF    = 8;
localparam integer SLV_ON     = 3;          // read-slot slave pull-down window
localparam integer SLV_OFF    = 5;
localparam integer EXTRA_P    = 20;         // phase tick of the injected collision
localparam integer GAP_N      = 3;
localparam integer ST_N       = 4;

localparam [1:0] CMD_RST  = 2'd1;
localparam [1:0] CMD_WR   = 2'd2;
localparam [1:0] CMD_RD   = 2'd3;
localparam [1:0] M_NONE   = 2'd0;
localparam [1:0] M_WIDE   = 2'd1;
localparam [1:0] M_NARROW = 2'd2;
localparam [1:0] M_DEAD   = 2'd3;
localparam [2:0] ST_IDLE  = 3'd0;

localparam [7:0] PD0  = 8'h00;
localparam [7:0] PD1  = 8'h00;
localparam [7:0] PD2  = 8'h5A;
localparam [7:0] PD3  = 8'hC3;
localparam [7:0] PD4  = 8'h3C;
localparam [7:0] PD5  = 8'h5A;
localparam [7:0] PD6  = 8'h4C;
localparam [7:0] PD7  = 8'h0F;
localparam [7:0] CRCB = 8'h51;              // CRC8 of PD0..PD7 (Maxim poly)
localparam [7:0] PDB4 = 8'h34;              // PD4 with bit 3 corrupted on the wire

localparam [31:0] SEED = 32'h0BE512F5;

reg        rst_n;
reg        clk_en;
reg        tick;
reg        ow_i;
reg [1:0]  cmd;
reg        cmd_valid;
reg [7:0]  wdata;
reg        crc_en;
reg        crc_end;
reg [31:0] state;

wire        ow_oe;
wire        done;
wire [2:0]  st_q;
wire [5:0]  tc;
wire [2:0]  bit_idx;
wire [7:0]  rx_word;
wire [7:0]  tx_word;
wire [7:0]  crc;
wire [3:0]  byte_count;
wire        presence;
wire        nopre_sticky;
wire        crc_sticky;
wire        len_sticky;
wire        busy_sticky;
wire        bad_cmd_sticky;
wire [3:0]  rst_count;
wire [3:0]  crc_count;
wire [3:0]  err_count;

reg        tick_b [0:MAXB - 1];
reg        en_b   [0:MAXB - 1];
reg        slv_b  [0:MAXB - 1];
reg        cv_b   [0:MAXB - 1];
reg [1:0]  cmd_b  [0:MAXB - 1];
reg [7:0]  dat_b  [0:MAXB - 1];
reg        cre_b  [0:MAXB - 1];
reg        cnd_b  [0:MAXB - 1];
integer    chk_b  [0:7];
integer    chk_k  [0:7];

reg        cur_tick;
reg        cur_en;
reg        cur_slv;
reg        cur_cv;
reg [1:0]  cur_cmd;
reg [7:0]  cur_dat;
reg        cur_cren;
reg        cur_cend;
reg [7:0]  pd [0:8];

integer    nb;
integer    nbeats;
integer    nchk;
integer    last_pb;
integer    i;
integer    k;
reg [31:0] w1;
reg [31:0] w2;
reg [31:0] w3;
reg [31:0] pw1;
reg        bad;
reg        dump;

// No #() override here: the testbench exercises the shipped default geometry,
// which is the configuration the manifest records.
ips_one_wire_master dut (
    .clk           (ips_clk),
    .clk_en        (clk_en),
    .rst_n         (rst_n),
    .tick          (tick),
    .ow_i          (ow_i),
    .cmd           (cmd),
    .cmd_valid     (cmd_valid),
    .wdata         (wdata),
    .crc_en        (crc_en),
    .crc_end       (crc_end),
    .ow_oe         (ow_oe),
    .done          (done),
    .state         (st_q),
    .tc            (tc),
    .bit_idx       (bit_idx),
    .rx_word       (rx_word),
    .tx_word       (tx_word),
    .crc           (crc),
    .byte_count    (byte_count),
    .presence      (presence),
    .nopre_sticky  (nopre_sticky),
    .crc_sticky    (crc_sticky),
    .len_sticky    (len_sticky),
    .busy_sticky   (busy_sticky),
    .bad_cmd_sticky(bad_cmd_sticky),
    .rst_count     (rst_count),
    .crc_count     (crc_count),
    .err_count     (err_count)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

function slv_lvl;
    input [7:0] sd;
    input integer j;
    input integer q;
    input [1:0]   md;
    reg         zero_bit;
    begin
        zero_bit = ~sd[j];
        if (!zero_bit) begin
            slv_lvl = 1'b0;
        end else begin
            case (md)
                M_WIDE:   slv_lvl = ((q >= SLV_ON) && (q <= SLV_OFF));
                M_NARROW: slv_lvl = (q == SLV_ON);
                default:  slv_lvl = 1'b0;
            endcase
        end
    end
endfunction

task PB;
    begin
        tick_b[nb] = cur_tick;
        en_b[nb]   = cur_en;
        slv_b[nb]  = cur_slv;
        cv_b[nb]   = cur_cv;
        cmd_b[nb]  = cur_cmd;
        dat_b[nb]  = cur_dat;
        cre_b[nb]  = cur_cren;
        cnd_b[nb]  = cur_cend;
        last_pb    = nb;
        nb         = nb + 1;
    end
endtask

task CHK;
    input integer kind;
    begin
        chk_b[nchk] = last_pb;
        chk_k[nchk] = kind;
        nchk        = nchk + 1;
    end
endtask

task GAPB;
    input integer n;
    begin
        cur_tick = 1'b0;
        repeat (n) begin
            PB;
        end
        cur_tick = 1'b1;
    end
endtask

task STLB;
    input integer n;
    begin
        cur_en = 1'b0;
        repeat (n) begin
            PB;
        end
        cur_en = 1'b1;
    end
endtask

task RST_ENT;
    input       pre;
    input       gapf;
    input       stf;
    integer     p;
    begin
        cur_tick = 1'b1;
        cur_en   = 1'b1;
        cur_slv  = 1'b0;
        cur_cv   = 1'b1;
        cur_cmd  = CMD_RST;
        cur_dat  = 8'h00;
        cur_cren = 1'b0;
        cur_cend = 1'b0;
        PB;
        for (p = 0; p <= PRE_END_TB; p = p + 1) begin
            cur_cv   = 1'b0;
            cur_cmd  = 2'd0;
            cur_cren = 1'b0;
            cur_cend = 1'b0;
            cur_slv  = (pre && (p >= PRE_ON) && (p <= PRE_OFF)) ? 1'b1 : 1'b0;
            PB;
            if (gapf && (p == PRE_ON)) begin
                GAPB(GAP_N);
            end
            if (stf && (p == 9)) begin
                STLB(ST_N);
            end
        end
    end
endtask

task BYTE_ENT;
    input [1:0] cm;
    input [7:0] dt;
    input [7:0] sd;
    input [1:0] md;
    input       ce;
    input       cd;
    input       coll;
    input       gapf;
    input       stf;
    input [2:0] kind;
    integer     p;
    integer     j;
    integer     q;
    begin
        cur_tick = 1'b1;
        cur_en   = 1'b1;
        cur_slv  = 1'b0;
        cur_cv   = 1'b1;
        cur_cmd  = cm;
        cur_dat  = dt;
        cur_cren = ce;
        cur_cend = cd;
        PB;
        for (p = 0; p < SLOT * BITS; p = p + 1) begin
            j        = p / SLOT;
            q        = p % SLOT;
            cur_cv   = (coll && (p == EXTRA_P)) ? 1'b1 : 1'b0;
            cur_cmd  = cur_cv ? CMD_WR : 2'd0;
            cur_dat  = 8'h00;
            cur_cren = 1'b0;
            cur_cend = 1'b0;
            cur_slv  = (cm == CMD_RD) ? slv_lvl(sd, j, q, md) : 1'b0;
            PB;
            if (gapf && (p == SLOT + SLV_ON)) begin
                GAPB(GAP_N);
            end
            if (stf && (p == 3 * SLOT + 1)) begin
                STLB(ST_N);
            end
        end
        if (kind != 0) begin
            CHK(kind);
        end
    end
endtask

task BAD_ENT;
    begin
        cur_tick = 1'b1;
        cur_en   = 1'b1;
        cur_slv  = 1'b0;
        cur_cv   = 1'b1;
        cur_cmd  = 2'd0;
        cur_dat  = 8'hA5;
        cur_cren = 1'b0;
        cur_cend = 1'b0;
        PB;
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    tick      = 1'b0;
    ow_i      = 1'b1;
    cmd       = 2'd0;
    cmd_valid = 1'b0;
    wdata     = 8'h00;
    crc_en    = 1'b0;
    crc_end   = 1'b0;
    state     = SEED;
    bad       = 1'b0;
    dump      = $test$plusargs("DUMP");
    nb        = 0;
    nchk      = 0;

    pd[0] = PD0; pd[1] = PD1; pd[2] = PD2; pd[3] = PD3; pd[4] = PD4;
    pd[5] = PD5; pd[6] = PD6; pd[7] = PD7; pd[8] = CRCB;

    // ---- plan ---------------------------------------------------------------
    RST_ENT(1'b1, 1'b0, 1'b0);                 // presence detected
    BYTE_ENT(CMD_WR, 8'hF3, 8'h00, M_NONE, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

    for (k = 0; k < 9; k = k + 1) begin        // good scratchpad block
        BYTE_ENT(CMD_RD, 8'h00, pd[k], M_WIDE, 1'b1, (k == 8), 1'b0,
                 (k == 4), (k == 1), (k == 8) ? 3'd1 : 3'd0);
    end

    RST_ENT(1'b0, 1'b1, 1'b0);                 // no presence -> error path
    RST_ENT(1'b1, 1'b0, 1'b1);

    state = state * 32'd1664525 + 32'd1013904223;
    BYTE_ENT(CMD_WR, state[7:0], 8'h00, M_NONE, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
    state = state * 32'd1664525 + 32'd1013904223;
    BYTE_ENT(CMD_RD, 8'h00, state[7:0], M_DEAD, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
    BAD_ENT();

    for (k = 0; k < 9; k = k + 1) begin        // corrupted block -> CRC flag
        BYTE_ENT(CMD_RD, 8'h00, (k == 4) ? PDB4 : pd[k], M_WIDE, 1'b1, (k == 8), 1'b0,
                 1'b0, (k == 6), (k == 8) ? 3'd2 : 3'd0);
    end

    state = state * 32'd1664525 + 32'd1013904223;
    BYTE_ENT(CMD_RD, 8'h00, 8'h5A, M_NARROW, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
    state = state * 32'd1664525 + 32'd1013904223;
    BYTE_ENT(CMD_RD, 8'h00, 8'h0F, M_NARROW, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);

    RST_ENT(state[20], 1'b0, 1'b0);            // LCG-selected presence

    for (k = 0; k < 4; k = k + 1) begin        // short block -> length flag
        state = state * 32'd1664525 + 32'd1013904223;
        BYTE_ENT(CMD_RD, 8'h00, state[7:0], M_WIDE, 1'b1, (k == 3), 1'b0,
                 1'b0, 1'b0, (k == 3) ? 3'd3 : 3'd0);
    end

    state = state * 32'd1664525 + 32'd1013904223;
    BYTE_ENT(CMD_WR, state[15:8], 8'h00, M_NONE, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
    state = state * 32'd1664525 + 32'd1013904223;
    BYTE_ENT(CMD_RD, 8'h00, state[7:0], M_NARROW, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
    RST_ENT(1'b1, 1'b0, 1'b0);

    nbeats = nb;

    // ---- run ----------------------------------------------------------------
    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    if (nbeats < 200 || nbeats >= MAXB || nchk != 3) bad = 1'b1;

    for (i = 0; i < nbeats; i = i + 1) begin
        @(negedge ips_clk);
        tick      = tick_b[i];
        clk_en    = en_b[i];
        cmd_valid = cv_b[i];
        cmd       = cmd_b[i];
        wdata     = dat_b[i];
        crc_en    = cre_b[i];
        crc_end   = cnd_b[i];
        ow_i      = ~(ow_oe | slv_b[i]);

        @(negedge ips_clk);
        clk_en    = 1'b0;
        cmd_valid = 1'b0;

        w1 = {18'd0, tc, bit_idx, st_q, ow_oe, done};
        w2 = {8'd0, rx_word, tx_word, byte_count};
        w3 = {14'd0, nopre_sticky, crc_sticky, len_sticky, busy_sticky, bad_cmd_sticky,
              presence, rst_count, crc_count, err_count};

        if ((^st_q === 1'bx) || (^tc === 1'bx) || (^bit_idx === 1'bx))              bad = 1'b1;
        if ((^rx_word === 1'bx) || (^tx_word === 1'bx) || (^crc === 1'bx))          bad = 1'b1;
        if ((^byte_count === 1'bx) || (^rst_count === 1'bx))                        bad = 1'b1;
        if ((^crc_count === 1'bx) || (^err_count === 1'bx))                         bad = 1'b1;
        if ((ow_oe === 1'bx) || (done === 1'bx) || (presence === 1'bx))             bad = 1'b1;
        if ((nopre_sticky === 1'bx) || (crc_sticky === 1'bx) || (len_sticky === 1'bx)) bad = 1'b1;
        if ((busy_sticky === 1'bx) || (bad_cmd_sticky === 1'bx))                    bad = 1'b1;
        // structural invariants of the written contract
        if ((done === 1'b1) && (st_q !== ST_IDLE))                                  bad = 1'b1;
        if ((crc_sticky === 1'b0) && (crc_count !== 4'h0))                          bad = 1'b1;
        if ((err_count === 4'h0) && (nopre_sticky || crc_sticky || len_sticky ||
                                     busy_sticky || bad_cmd_sticky))                bad = 1'b1;
        if ((i > 0) && ((en_b[i] === 1'b0) || (tick_b[i] === 1'b0)) && (w1 !== pw1)) bad = 1'b1;
        // the marked blocks must be judged the way they were built
        if ((i === chk_b[0]) && ((done !== 1'b1) || (crc_sticky !== 1'b0)))         bad = 1'b1;
        if ((i === chk_b[1]) && ((done !== 1'b1) || (crc_sticky !== 1'b1)))         bad = 1'b1;
        if ((i === chk_b[2]) && ((done !== 1'b1) || (len_sticky !== 1'b1)))         bad = 1'b1;

        ips_fnv_word(w1);
        ips_fnv_word(w2);
        ips_fnv_word(w3);
        if (done === 1'b1) begin
            ips_fnv_word({24'd0, crc});
        end
        pw1 = w1;
        if (dump && ((i % 64) == 63)) $display("DBG %0d %h %h %h", i, w1, w2, w3);
    end

    if (!((nopre_sticky === 1'b1) && (crc_sticky === 1'b1) && (len_sticky === 1'b1) &&
          (busy_sticky === 1'b1) && (bad_cmd_sticky === 1'b1)))                     bad = 1'b1;

    ips_fnv_word(nbeats);
    ips_fnv_word({17'd0, state[2:0], rst_count, crc_count, err_count});
    ips_verdict(!bad, "ips_one_wire_master");
end

endmodule
