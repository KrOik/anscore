`timescale 1ns / 1ps
// ips_hmac_sha256_wrap : HMAC-SHA-256 wrapper over a single iterative,
// byte-serial SHA-256 engine.  Key handling, ipad/opad fold, standard SHA-256
// block padding, the compression datapath, the digest result and the byte
// handshake counters all live in this one module.
//
// Contract -- FIPS 180-4 SHA-256 plus RFC 2104 HMAC, which is exactly what
// models/ips_hmac_sha256_wrap.py recomputes independently with Python's
// hashlib/hmac:
//   block feed  : 64 bytes, most significant byte first, big-endian words
//   padding     : 0x80, then zero bytes up to byte 55 of the last block, then
//                 the 64-bit big-endian BIT length of the fed stream
//   compression : 64 rounds, one round per beat; with the schedule window held
//                 as W[t..t+15] at the start of round t, W[t] is w0 and the
//                 inserted word is W[t+16] = sigma1(w14) + w9 + sigma0(w1) + w0
//   HMAC        : K' = (len(K) > 64) ? SHA256(K) : K
//                 inner = SHA256((K' xor ipad) || M)
//                 outer = SHA256((K' xor opad) || inner)
//
// Pass structure (this is the handshake contract the testbench folds and the
// model re-derives):
//   pass 0 key hash  only when key_long.  The key bytes stream straight into
//          the engine while they are being stored, so a key of len(K) > 64 is
//          already half hashed when klast closes the stream; the padding tail
//          then finishes it and SHA256(K) is captured in the kh[] byte array.
//   pass 1 inner     64 head bytes (key byte xor IPAD_B, zero bytes from
//          head_lim up), then the message bytes from the port, then the padding
//          tail whose length field is 8 * (64 + len(M)).  The digest is
//          captured in dg[].
//   pass 2 outer     64 head bytes (key byte xor OPAD_B), then the DGST_BYTES
//          inner-digest bytes out of dg[], then the padding tail.
//   A 64-byte block costs exactly 64 absorb beats plus 64 round beats: every
//   absorb beat that completes a block inserts a round run first, so ready is
//   low for exactly 64 beats at every block boundary -- including boundaries in
//   the middle of the message stream and inside a padding tail.  The marker
//   beats S_KFIN, S_IDIG, S_INI and S_DONE cost one beat each.  round carries
//   the index of the round being executed (0..63) and reads 0 on every other
//   beat; blk_cnt counts completed compressions and is cleared only by start.
//
// Byte handshake: accepted key bytes land in kf[] (indices at or above the
// block size are dropped, because such a key is hashed down and kf[] is not
// used then), accepted message bytes only advance the engine.  Activity on a
// closed stream is refused and recorded with first-error-wins, and a byte
// offered while ready is low is simply not consumed -- the bus is not free.
//
// Storage and datapath notes: kf/kh/dg/sn are loaded straight off the engine
// state wires with a clock enable, so those write ports need no 32-bit
// multiplexer; the 16-word schedule window is a shift-left register with one
// enable, so every stage is wiring plus a clock enable and only the inserted
// word costs a multiplexer, and the same shift serves both the absorb and the
// round phase; the chaining value lives in the state registers themselves, so
// `digest` is the frozen state after done and no separate 256-bit result
// register is needed.
//
// AREA: this is a deliberately straightforward one-round-per-beat datapath and
// it does NOT fit the 600 LUT-class budget under `synth_gowin -noalu`; the
// synthesis station is reported red with the measured number instead of the
// budget being reinterpreted.
//
// FUNCTIONAL PROTOTYPE ONLY: not verified for constant-time behaviour, glitch
// behaviour or side channels; board evidence is DEFERRED.
module ips_hmac_sha256_wrap (
    input  wire          clk,
    input  wire          clk_en,
    input  wire          rst_n,

    input  wire          start,

    input  wire          kvalid,
    input  wire  [7:0]   kdata,
    input  wire          klast,

    input  wire          mvalid,
    input  wire  [7:0]   mdata,
    input  wire          mlast,

    output wire          ready,
    output wire [255:0]  digest,

    output reg           digest_vld,
    output reg           done,
    output reg           busy,
    output reg           key_long,
    output reg  [2:0]    err,
    output reg  [1:0]    pass_no,
    output reg  [7:0]    blk_cnt,
    output reg  [6:0]    round,
    output reg  [15:0]   key_len,
    output reg  [15:0]   msg_len
);

localparam [7:0]   IPAD_B     = 8'h36;   // RFC 2104 inner pad byte
localparam [7:0]   OPAD_B     = 8'h5c;   // RFC 2104 outer pad byte
localparam [6:0]   BLK_BYTES  = 7'd64;   // SHA-256 block feed length
localparam [5:0]   DGST_BYTES = 6'd32;   // digest bytes fed by the outer pass
localparam [31:0]  IV0        = 32'h6a09e667;
localparam [31:0]  IV1        = 32'hbb67ae85;
localparam [31:0]  IV2        = 32'h3c6ef372;
localparam [31:0]  IV3        = 32'ha54ff53a;
localparam [31:0]  IV4        = 32'h510e527f;
localparam [31:0]  IV5        = 32'h9b05688c;
localparam [31:0]  IV6        = 32'h1f83d9ab;
localparam [31:0]  IV7        = 32'h5be0cd19;

localparam [15:0]  BLK16      = {9'd0, BLK_BYTES};
localparam [15:0]  HEAD_END   = 16'd63;
localparam [15:0]  ODIG_END   = 16'd64 + {10'd0, DGST_BYTES} - 16'h0001;
localparam [7:0]   PAD_MARK   = 8'h80;   // the mandatory one bit byte
localparam [6:0]   RND_LAST   = 7'd63;
localparam [6:0]   PAD_LAST   = 7'd55;   // last zero pad byte position
localparam [6:0]   FAR_LAST   = 7'd119;  // 55 + 64, for a tail that spills over
localparam [6:0]   LEN_BYTES  = 7'd8;    // big-endian 64-bit length field

localparam [2:0]   ERR_NONE    = 3'd0;
localparam [2:0]   ERR_RESTART = 3'd1;
localparam [2:0]   ERR_MOVER   = 3'd2;
localparam [2:0]   ERR_KOVER   = 3'd3;
localparam [2:0]   ERR_NOK     = 3'd4;

localparam [3:0]   S_IDLE  = 4'd0;
localparam [3:0]   S_KEY   = 4'd1;
localparam [3:0]   S_MSG   = 4'd2;
localparam [3:0]   S_HEAD  = 4'd3;
localparam [3:0]   S_ODIG  = 4'd4;
localparam [3:0]   S_TAIL  = 4'd5;
localparam [3:0]   S_ROUND = 4'd6;
localparam [3:0]   S_KFIN  = 4'd7;
localparam [3:0]   S_IDIG  = 4'd8;
localparam [3:0]   S_INI   = 4'd9;
localparam [3:0]   S_DONE  = 4'd10;

// ---- engine registers --------------------------------------------------------
reg [3:0]  st;
reg [3:0]  ret;               // state to enter when a round run ends
reg [3:0]  tret;              // state to enter when the padding tail ends
reg [15:0] fi;                // feed byte index inside the current pass
reg [7:0]  pad_const;
reg [15:0] head_lim;
reg [6:0]  nz;                // zero pad bytes in the current tail
reg [6:0]  tp;                // tail byte position, 0 = the 0x80 byte
reg        key_closed;
reg        msg_closed;
reg [63:0] lenbits;

reg [31:0] a, b, c, d, e, f, g, h;
reg [31:0] sn_a, sn_b, sn_c, sn_d, sn_e, sn_f, sn_g, sn_h;
reg [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
reg [31:0] w8, w9, w10, w11, w12, w13, w14, w15;
reg [31:0] wasm;

reg [7:0] kf [0:63];
reg [7:0] kh [0:31];
reg [7:0] dg [0:31];
integer  li;

wire [255:0] stv = {a, b, c, d, e, f, g, h};
assign digest = stv;

// ---- sequencing ------------------------------------------------------------
wire in_round = (st == S_ROUND);
wire rdy      = ~in_round & ((st == S_KEY) | (st == S_MSG));
assign ready  = rdy;

wire k_acc = rdy & (st == S_KEY) & kvalid;
wire m_acc = rdy & (st == S_MSG) & mvalid;

wire gen_beat = (st == S_HEAD) | (st == S_ODIG) | (st == S_TAIL);
wire fbeat    = k_acc | m_acc | gen_beat;

wire [15:0] fi_nx    = fi + 16'h0001;
wire        word_stb = fbeat & (fi[1:0] == 2'b11);
wire        blk_full = word_stb & (fi[5:2] == 4'hF);
wire        sh_en    = word_stb | in_round;

wire        kl_now   = key_long | (k_acc & (key_len >= BLK16));
wire        tail_last = (st == S_TAIL) & (tp == (nz + LEN_BYTES));

wire [5:0]  rem_n   = fi_nx[5:0];
wire [6:0]  nz_calc = (rem_n <= PAD_LAST) ? (PAD_LAST - rem_n)
                                          : (FAR_LAST - {1'b0, rem_n});

wire [3:0] nxt_key  = (k_acc & klast) ? (kl_now ? S_TAIL : S_INI) : S_KEY;
wire [3:0] nxt_msg  = (m_acc & mlast) ? S_TAIL : S_MSG;
wire [3:0] nxt_head = (fi == HEAD_END) ? ((pass_no == 2'h1) ? S_MSG : S_ODIG) : S_HEAD;
wire [3:0] nxt_odig = (fi == ODIG_END) ? S_TAIL : S_ODIG;
wire [3:0] nxt_tail = tail_last ? tret : S_TAIL;

wire [3:0] nxt = (st == S_KEY)   ? nxt_key   :
                 (st == S_MSG)   ? nxt_msg   :
                 (st == S_HEAD)  ? nxt_head  :
                 (st == S_ODIG)  ? nxt_odig  :
                 (st == S_TAIL)  ? nxt_tail  :
                 (st == S_ROUND) ? ret       :
                 (st == S_KFIN)  ? S_INI     :
                 (st == S_IDIG)  ? S_INI     :
                 (st == S_INI)   ? S_HEAD    :
                 (st == S_DONE)  ? S_IDLE    :
                                   S_IDLE;

wire enter_tail  = (nxt == S_TAIL) & (st != S_TAIL);
wire go_round    = blk_full | tail_last;
wire [3:0] ret_a = (st == S_TAIL) ? tret : nxt;

wire e_restart = start & busy;
wire e_mover   = mvalid & msg_closed;
wire e_kover   = kvalid & key_closed;
wire e_nok     = mvalid & rdy & (st == S_KEY);

wire [2:0] new_err = e_restart ? ERR_RESTART :
                     e_mover   ? ERR_MOVER   :
                     e_kover   ? ERR_KOVER   :
                     e_nok     ? ERR_NOK     : ERR_NONE;

// ---- round datapath --------------------------------------------------------
wire [31:0] e_r6  = {e[5:0],  e[31:6]};
wire [31:0] e_r11 = {e[10:0], e[31:11]};
wire [31:0] e_r25 = {e[24:0], e[31:25]};
wire [31:0] a_r2  = {a[1:0],  a[31:2]};
wire [31:0] a_r13 = {a[12:0], a[31:13]};
wire [31:0] a_r22 = {a[21:0], a[31:22]};

wire [31:0] big1 = e_r6 ^ e_r11 ^ e_r25;
wire [31:0] chv  = (e & f) ^ (~e & g);
wire [31:0] big0 = a_r2 ^ a_r13 ^ a_r22;
wire [31:0] majv = (a & b) ^ (a & c) ^ (b & c);

function [31:0] k_const;
    input [5:0] t;
    begin
        case (t)
            6'd0:  k_const = 32'h428a2f98; 6'd1:  k_const = 32'h71374491;
            6'd2:  k_const = 32'hb5c0fbcf; 6'd3:  k_const = 32'he9b5dba5;
            6'd4:  k_const = 32'h3956c25b; 6'd5:  k_const = 32'h59f111f1;
            6'd6:  k_const = 32'h923f82a4; 6'd7:  k_const = 32'hab1c5ed5;
            6'd8:  k_const = 32'hd807aa98; 6'd9:  k_const = 32'h12835b01;
            6'd10: k_const = 32'h243185be; 6'd11: k_const = 32'h550c7dc3;
            6'd12: k_const = 32'h72be5d74; 6'd13: k_const = 32'h80deb1fe;
            6'd14: k_const = 32'h9bdc06a7; 6'd15: k_const = 32'hc19bf174;
            6'd16: k_const = 32'he49b69c1; 6'd17: k_const = 32'hefbe4786;
            6'd18: k_const = 32'h0fc19dc6; 6'd19: k_const = 32'h240ca1cc;
            6'd20: k_const = 32'h2de92c6f; 6'd21: k_const = 32'h4a7484aa;
            6'd22: k_const = 32'h5cb0a9dc; 6'd23: k_const = 32'h76f988da;
            6'd24: k_const = 32'h983e5152; 6'd25: k_const = 32'ha831c66d;
            6'd26: k_const = 32'hb00327c8; 6'd27: k_const = 32'hbf597fc7;
            6'd28: k_const = 32'hc6e00bf3; 6'd29: k_const = 32'hd5a79147;
            6'd30: k_const = 32'h06ca6351; 6'd31: k_const = 32'h14292967;
            6'd32: k_const = 32'h27b70a85; 6'd33: k_const = 32'h2e1b2138;
            6'd34: k_const = 32'h4d2c6dfc; 6'd35: k_const = 32'h53380d13;
            6'd36: k_const = 32'h650a7354; 6'd37: k_const = 32'h766a0abb;
            6'd38: k_const = 32'h81c2c92e; 6'd39: k_const = 32'h92722c85;
            6'd40: k_const = 32'ha2bfe8a1; 6'd41: k_const = 32'ha81a664b;
            6'd42: k_const = 32'hc24b8b70; 6'd43: k_const = 32'hc76c51a3;
            6'd44: k_const = 32'hd192e819; 6'd45: k_const = 32'hd6990624;
            6'd46: k_const = 32'hf40e3585; 6'd47: k_const = 32'h106aa070;
            6'd48: k_const = 32'h19a4c116; 6'd49: k_const = 32'h1e376c08;
            6'd50: k_const = 32'h2748774c; 6'd51: k_const = 32'h34b0bcb5;
            6'd52: k_const = 32'h391c0cb3; 6'd53: k_const = 32'h4ed8aa4a;
            6'd54: k_const = 32'h5b9cca4f; 6'd55: k_const = 32'h682e6ff3;
            6'd56: k_const = 32'h748f82ee; 6'd57: k_const = 32'h78a5636f;
            6'd58: k_const = 32'h84c87814; 6'd59: k_const = 32'h8cc70208;
            6'd60: k_const = 32'h90befffa; 6'd61: k_const = 32'ha4506ceb;
            6'd62: k_const = 32'hbef9a3f7; 6'd63: k_const = 32'hc67178f2;
            default: k_const = 32'h00000000;
        endcase
    end
endfunction

wire [31:0] t1v = h + big1 + chv + k_const(round[5:0]) + w0;
wire [31:0] t2v = big0 + majv;

wire [31:0] w1_s0 = {w1[6:0],  w1[31:7]};
wire [31:0] w1_s1 = {w1[17:0], w1[31:18]};
wire [31:0] w1_s2 = {3'd0,     w1[31:3]};
wire [31:0] w14_s0 = {w14[16:0], w14[31:17]};
wire [31:0] w14_s1 = {w14[18:0], w14[31:19]};
wire [31:0] w14_s2 = {10'd0,     w14[31:10]};
wire [31:0] sig0v = w1_s0 ^ w1_s1 ^ w1_s2;
wire [31:0] sig1v = w14_s0 ^ w14_s1 ^ w14_s2;
wire [31:0] ws    = sig1v + w9 + sig0v + w0;

wire [31:0] a_nx = t1v + t2v;
wire [31:0] e_nx = d + t1v;

// ---- byte read paths -------------------------------------------------------
reg [7:0] rd_kf, rd_kh, rd_dg;
always @(*) begin
    rd_kf = kf[fi[5:0]];
    rd_kh = kh[fi[4:0]];
    rd_dg = dg[fi[4:0]];
end

wire [7:0] raw_head  = key_long ? rd_kh : rd_kf;
wire [7:0] head_byte = ((fi < head_lim) ? raw_head : 8'h00) ^ pad_const;
wire [7:0] reg_byte  = (st == S_ODIG) ? rd_dg : head_byte;

wire [2:0] len_idx = tp[2:0] - nz[2:0] - 3'd1;
reg  [7:0] len_byte;
always @(*) begin
    case (len_idx)
        3'd0:    len_byte = lenbits[63:56];
        3'd1:    len_byte = lenbits[55:48];
        3'd2:    len_byte = lenbits[47:40];
        3'd3:    len_byte = lenbits[39:32];
        3'd4:    len_byte = lenbits[31:24];
        3'd5:    len_byte = lenbits[23:16];
        3'd6:    len_byte = lenbits[15:8];
        default: len_byte = lenbits[7:0];
    endcase
end

wire [7:0] tail_byte = (tp == 7'd0) ? PAD_MARK :
                       (tp <= nz)   ? 8'h00    :
                                      len_byte;

wire [7:0] fbyte = (st == S_KEY)   ? kdata     :
                   (st == S_MSG)   ? mdata     :
                   (st == S_TAIL)  ? tail_byte :
                                     reg_byte;

wire [31:0] asm_word = {wasm[23:0], fbyte};

// ---- registered behaviour --------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st         <= S_IDLE;
        ret        <= S_IDLE;
        tret       <= S_IDLE;
        fi         <= 16'h0000;
        pad_const  <= IPAD_B;
        head_lim   <= 16'h0000;
        nz         <= 7'h00;
        tp         <= 7'h00;
        lenbits    <= 64'h0;
        key_closed <= 1'b0;
        msg_closed <= 1'b0;
        a <= 32'h00000000; b <= 32'h00000000;
        c <= 32'h00000000; d <= 32'h00000000;
        e <= 32'h00000000; f <= 32'h00000000;
        g <= 32'h00000000; h <= 32'h00000000;
        sn_a <= 32'h00000000; sn_b <= 32'h00000000;
        sn_c <= 32'h00000000; sn_d <= 32'h00000000;
        sn_e <= 32'h00000000; sn_f <= 32'h00000000;
        sn_g <= 32'h00000000; sn_h <= 32'h00000000;
        w0 <= 32'h00000000; w1 <= 32'h00000000;
        w2 <= 32'h00000000; w3 <= 32'h00000000;
        w4 <= 32'h00000000; w5 <= 32'h00000000;
        w6 <= 32'h00000000; w7 <= 32'h00000000;
        w8 <= 32'h00000000; w9 <= 32'h00000000;
        w10 <= 32'h00000000; w11 <= 32'h00000000;
        w12 <= 32'h00000000; w13 <= 32'h00000000;
        w14 <= 32'h00000000; w15 <= 32'h00000000;
        wasm       <= 32'h00000000;
        digest_vld <= 1'b0;
        done       <= 1'b0;
        busy       <= 1'b0;
        key_long   <= 1'b0;
        err        <= ERR_NONE;
        pass_no    <= 2'h0;
        blk_cnt    <= 8'h00;
        round      <= 7'h00;
        key_len    <= 16'h0000;
        msg_len    <= 16'h0000;
        for (li = 0; li < 64; li = li + 1) kf[li] <= 8'h00;
        for (li = 0; li < 32; li = li + 1) begin
            kh[li] <= 8'h00;
            dg[li] <= 8'h00;
        end
    end else if (clk_en) begin
        // ---------------- byte feed ----------------
        if (k_acc) begin
            if (key_len < BLK16) kf[key_len[5:0]] <= kdata;
            key_len <= key_len + 16'h0001;
            wasm    <= {wasm[23:0], kdata};
            if (klast)                    key_closed <= 1'b1;
            if (key_len >= BLK16)         key_long   <= 1'b1;
        end else if (m_acc) begin
            msg_len <= msg_len + 16'h0001;
            wasm    <= {wasm[23:0], mdata};
            if (mlast) msg_closed <= 1'b1;
        end else if (gen_beat) begin
            wasm <= {wasm[23:0], fbyte};
        end

        if (fbeat) fi <= fi_nx;

        if (sh_en) begin
            w0  <= w1;  w1  <= w2;  w2  <= w3;  w3  <= w4;
            w4  <= w5;  w5  <= w6;  w6  <= w7;  w7  <= w8;
            w8  <= w9;  w9  <= w10; w10 <= w11; w11 <= w12;
            w12 <= w13; w13 <= w14; w14 <= w15;
            w15 <= in_round ? ws : asm_word;
        end

        if (blk_full) begin
            sn_a <= a; sn_b <= b; sn_c <= c; sn_d <= d;
            sn_e <= e; sn_f <= f; sn_g <= g; sn_h <= h;
        end

        if (in_round) begin
            if (round == RND_LAST) begin
                a <= a_nx + sn_a;
                b <= a    + sn_b;
                c <= b    + sn_c;
                d <= c    + sn_d;
                e <= e_nx + sn_e;
                f <= e    + sn_f;
                g <= f    + sn_g;
                h <= g    + sn_h;
                round   <= 7'h00;
                blk_cnt <= blk_cnt + 8'h01;
            end else begin
                a <= a_nx;
                b <= a;
                c <= b;
                d <= c;
                e <= e_nx;
                f <= e;
                g <= f;
                h <= g;
                round <= round + 7'h01;
            end
        end else if (st == S_INI) begin
            a <= IV0; b <= IV1; c <= IV2; d <= IV3;
            e <= IV4; f <= IV5; g <= IV6; h <= IV7;
        end

        // ---------------- sequencing ----------------
        if (start) begin
            st         <= S_KEY;
            ret        <= S_IDLE;
            tret       <= S_IDLE;
            fi         <= 16'h0000;
            nz         <= 7'h00;
            tp         <= 7'h00;
            key_len    <= 16'h0000;
            msg_len    <= 16'h0000;
            blk_cnt    <= 8'h00;
            round      <= 7'h00;
            pass_no    <= 2'h0;
            key_closed <= 1'b0;
            msg_closed <= 1'b0;
            key_long   <= 1'b0;
            done       <= 1'b0;
            digest_vld <= 1'b0;
            busy       <= 1'b1;
            err        <= busy ? ERR_RESTART : ERR_NONE;
        end else begin
            st <= nxt;
            if (go_round) begin
                st  <= S_ROUND;
                ret <= ret_a;
            end

            if (enter_tail) begin
                lenbits <= {45'd0, fi_nx, 3'b000};
                nz      <= nz_calc;
                tp      <= 7'h00;
                tret    <= (st == S_KEY) ? S_KFIN :
                           (st == S_MSG) ? S_IDIG : S_DONE;
            end else if (st == S_TAIL) begin
                tp <= tp + 7'h01;
            end

            if (st == S_KFIN) begin
                for (li = 0; li < 32; li = li + 1)
                    kh[li] <= stv[(255 - 8*li) -: 8];
            end

            if (st == S_IDIG) begin
                for (li = 0; li < 32; li = li + 1)
                    dg[li] <= stv[(255 - 8*li) -: 8];
            end

            if (st == S_INI) begin
                head_lim  <= key_long ? {10'd0, DGST_BYTES} : key_len;
                pad_const <= msg_closed ? OPAD_B : IPAD_B;
                pass_no   <= msg_closed ? 2'h2 : 2'h1;
            end

            digest_vld <= (st == S_DONE);
            if (st == S_DONE) begin
                done <= 1'b1;
                busy <= 1'b0;
            end

            if ((new_err != ERR_NONE) & (err == ERR_NONE)) err <= new_err;
        end
    end
end

endmodule
