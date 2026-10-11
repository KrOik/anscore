`timescale 1ns / 1ps
// ips_speck128_block : bit-serial SPECK128/128 block cipher engine, encryption
// direction only, with the serialisation options the manifest asks for: the key
// and the block enter over a 32-bit WORD-serial bus, and every round is executed
// BIT-serially over one 64-beat lap of a recirculating ring.
//
// Contract -- the published NSA "SIMON and SPECK Implementation Guide" 1.1
// (sections 6, 7 and 16), which is also what models/ips_speck128_block.py
// implements independently:
//   round function  ER64(x,y,k): x = (ROTR64(x,8) + y) ^ k ; y = ROTL64(y,3) ^ x
//   key schedule    B = K[1], A = K[0], rk[0] = A, and rk[i+1] is the right output
//                   of ER64(B,A,i); 32 rounds need 31 schedule steps.
// One lap fuses one block round with one schedule step, exactly like the guide's
// Speck128128EncryptExpandKey: both use the A word the previous step produced, and
// no round key is ever stored in an array.
//
// Why bit-serial: synthesis is `synth_gowin -noalu` (docs/IP_CORE_SOP.md trap T12),
// so a 64-bit carry-propagate adder costs ~260 LUT-class cells and the two
// parallel adders a one-round-per-clock datapath needs (block + schedule) measured
// 1047 -- more than double this core's 480-cell budget.  A serial ring turns both
// additions into one 1-bit full adder each and the whole engine lands in the low
// hundreds of LUTs, at the cost of 64 clocks per round.
//
// Engine structure (all state lives in circulating shift rings, one bit per beat,
// least significant bit first because the carry must ripple upwards):
//   rings  xq, yq, aq, bq  (WORD_BITS each) hold the block halves Pt[1],Pt[0] and
//          the schedule words A = K[0], B = K[1]; bit p is consumed and its new
//          value re-inserted at the same beat, so a full lap rewrites the word and
//          the parallel content is the true word exactly at the lap boundary.
//   ER64 needs x[p+8] and b[p+8] (rotate RIGHT): those positions have already been
//          rewritten during the last ROT_X beats, so an ROT_X-entry shadow keeps the
//          old values for the wrap-around, and both additions therefore see old data.
//   ER64 needs y[p-3] and a[p-3] (rotate LEFT): the value consumed 3 beats earlier,
//          supplied by a 3-stage delay line on the rings' serial output.
//   ct_x / ct_y latch the rings' completed word at every lap end while running (and
//          at the end of the load), so the parallel block output is stable and
//          readable while the rings are mid-lap.
//   round key: the block round is keyed with A and the schedule step with the step
//          index, exactly like the guide's fused loop, and both are injected as one
//          extra XOR into the serial sum -- A_old[p] leaves the aq ring on the same
//          beat the block needs it, so no round key is ever stored or addressed.
//   align: the first lap after an accepted run only recirculates the rings.  It
//          costs one lap but it is what primes the rotate-right shadow, the
//          rotate-left delay line and the rotate-left wrap shadow with the words
//          that were just loaded, so every scored lap after it sees true pre-round
//          operands.  The wrap shadow exists because the tail bits a lap writes are
//          never read back out of the ring during that same lap, and the next lap's
//          first ROT_Y beats need exactly those bits.
//
// Protocol (one enabled clock edge = one beat; every count below is in beats):
//   start        opens an operation: lap counter, load counter, round counter,
//                schedule counter and error code are all cleared and the engine is
//                idle again.  ct_x / ct_y are NOT cleared, so the previous result
//                stays readable until this operation's load overwrites it.
//   load         LOAD_WORDS key words with kw_valid, then LOAD_WORDS block words
//                with bw_valid, least-significant word first and bit 0 of each word
//                first, one word per ld_ready beat.  The accepted beat injects
//                ld_word[0] itself and the core then serialises the remaining
//                BUS_BITS-1 bits, so a word owns exactly BUS_BITS beats and ld_ready
//                is low for the rest of them.  The words must come in that order:
//                the rings are filled positionally, so word n of a stream lands on
//                bit positions (n*BUS_BITS) mod WORD_BITS of its ring.
//                A = key words 0..1, B = key words 2..3, Pt[0] = block words 0..1,
//                Pt[1] = block words 2..3, i.e. A||B = K[0],K[1] and
//                Pt[0]||Pt[1] as the guide prints them.
//   run_req      requests the cipher.  It is granted only on a beat with the bus
//                drained (no word mid-serialisation) and both streams complete, and
//                then busy and align go up one beat later.
//   engine       one ALIGN lap (WORD_BITS beats) plus ROUNDS scored laps
//                (WORD_BITS beats each).  done goes up with busy at the end of the
//                last scored lap and ct_x / ct_y hold the ciphertext.
//   errors       malformed loading is recorded with first-error-wins and reported
//                with done: a 5th key word (ERR_KWORD), a 5th block word
//                (ERR_BWORD), key and block in one beat (ERR_MIXED), run before the
//                streams are complete or while an error is pending (ERR_SHORT), a
//                load or run while the engine runs or after it finished, or activity
//                sampled on the same beat as start (ERR_LATE).  Refused beats never
//                disturb the state, and a load beat that lands inside a word still
//                being serialised (ld_ready = 0) is ignored without an error code --
//                the bus is simply not free yet.  start is the only way to clear
//                status.
//
// Decryption is not implemented: the inverse needs the round keys in reverse order,
// which a fused on-the-fly schedule cannot produce.  FUNCTIONAL PROTOTYPE ONLY:
// this is a functional datapath -- constant-time behaviour, key-schedule resistance
// to leakage and glitch behaviour are NOT verified here and board evidence is
// DEFERRED.  Every vector used with this core is published, test-only data.
module ips_speck128_block #(
    parameter WORD_BITS  = 64,
    parameter ROUNDS     = 32,
    parameter LOAD_WORDS = 4,
    parameter BUS_BITS   = 32,
    parameter ROT_X      = 8,
    parameter ROT_Y      = 3,
    parameter POS_BITS   = 6,
    parameter IDX_BITS   = 6
)(
    input  wire                 clk,
    input  wire                 clk_en,
    input  wire                 rst_n,

    input  wire                 start,
    input  wire                 run_req,
    input  wire                 kw_valid,
    input  wire                 bw_valid,
    input  wire [BUS_BITS-1:0]  ld_word,

    output wire [WORD_BITS-1:0] ct_x,
    output wire [WORD_BITS-1:0] ct_y,
    output wire                 err,
    output wire                 ld_ready,
    output wire                 align,
    output wire [POS_BITS-1:0]  bit_pos,
    output reg  [IDX_BITS-1:0]  round_cnt,
    output reg  [IDX_BITS-1:0]  sched_cnt,
    output reg  [3:0]           key_cnt,
    output reg  [3:0]           blk_cnt,
    output reg  [2:0]           err_code,
    output reg                  done,
    output reg                  busy
);

localparam integer LDBITS    = 6;   // room for a BUS_BITS-long bit counter
localparam integer LAGW      = 4;   // rotate-left delay line depth
localparam integer SHDW      = 8;   // rotate-right shadow entries

localparam [2:0]  ERR_NONE   = 3'd0;
localparam [2:0]  ERR_KWORD  = 3'd1;
localparam [2:0]  ERR_BWORD  = 3'd2;
localparam [2:0]  ERR_MIXED  = 3'd3;
localparam [2:0]  ERR_SHORT  = 3'd4;
localparam [2:0]  ERR_LATE   = 3'd5;

localparam [POS_BITS-1:0] LAST_POS = WORD_BITS - 1;
localparam [POS_BITS-1:0] SHADOW_START = WORD_BITS - ROT_X;
localparam [POS_BITS-1:0] WRAP_START = WORD_BITS - ROT_Y;
localparam [LDBITS-1:0]   LAST_BIT = BUS_BITS - 1;

reg [WORD_BITS-1:0] xq;
reg [WORD_BITS-1:0] yq;
reg [WORD_BITS-1:0] aq;
reg [WORD_BITS-1:0] bq;
reg [WORD_BITS-1:0] ctx_r;
reg [WORD_BITS-1:0] cty_r;
reg [SHDW-1:0]      xsh;
reg [SHDW-1:0]      bsh;
reg [ROT_Y-1:0]     ywr;
reg [ROT_Y-1:0]     awr;
reg [LAGW-1:0]      y_lag;
reg [LAGW-1:0]      a_lag;
reg [BUS_BITS-1:0]  ld_sr;
reg [LDBITS-1:0]    ld_rem;
reg [POS_BITS-1:0]  pos;
reg                 carry_x;
reg                 carry_b;
reg                 ld_key;      // the in-flight word belongs to the key stream
reg                 ld_hi;       // and to its upper half (B / Pt[1])
reg                 aligning;
reg                 run_pend;
reg                 ld_done;

assign ct_x     = ctx_r;
assign ct_y     = cty_r;
assign err      = (err_code != ERR_NONE);
assign align    = aligning;
assign bit_pos  = pos;
// a word can be injected while no word is being serialised and the engine is idle
wire streams_open = (key_cnt != LOAD_WORDS[3:0]) | (blk_cnt != LOAD_WORDS[3:0]);
assign ld_ready   = ~busy & ~done & ~start & (ld_rem == {LDBITS{1'b0}}) & streams_open;

// ---- load path ---------------------------------------------------------------
wire accepting  = ~busy & ~done & ~start;
wire mix_req    = kw_valid &  bw_valid & accepting;
wire kw_req     = kw_valid & ~bw_valid & accepting;
wire bw_req     = bw_valid & ~kw_valid & accepting;
wire mid_word   = (ld_rem != {LDBITS{1'b0}});
wire kw_ovf     = kw_req & ~mid_word & ~streams_open;
wire bw_ovf     = bw_req & ~mid_word & ~streams_open;
wire kw_acc     = kw_req & ~mid_word &  (key_cnt != LOAD_WORDS[3:0]);
wire bw_acc     = bw_req & ~mid_word &  (blk_cnt != LOAD_WORDS[3:0]);
wire word_in    = kw_acc | bw_acc;
wire late_evt   = (kw_valid | bw_valid | run_req) & (busy | done);
// the ring destination of the in-flight word
wire dst_a      =  ld_key & ~ld_hi;
wire dst_b      =  ld_key &  ld_hi;
wire dst_y      = ~ld_key & ~ld_hi;
wire dst_x      = ~ld_key &  ld_hi;
wire in_load    = word_in | mid_word;
// the accepted beat injects bit 0 straight from the bus, ld_sr carries bits 1.. up
wire ld_bit     = word_in ? ld_word[0] : ld_sr[0];

// ---- serial ER64 ------------------------------------------------------------
wire x_out      = xq[0];                       // x[p], about to be replaced
wire y_out      = yq[0];
wire a_out      = aq[0];
wire b_out      = bq[0];
// rotate-right operands x[p+8], b[p+8]: the ring tap holds a stale (already
// rewritten) value during the last ROT_X beats, so the shadow covers those
wire x_fwd      = (pos >= SHADOW_START) ? xsh[pos[2:0]] : xq[ROT_X];
wire b_fwd      = (pos >= SHADOW_START) ? bsh[pos[2:0]] : bq[ROT_X];
// rotate-left operands y[p-3], a[p-3]: the value consumed ROT_Y beats earlier.
// the delay line shifts UP (the fresh bit lands in entry 0), so entry ROT_Y-1
// holds the ring output of ROT_Y beats back.
wire y_lap      = y_lag[ROT_Y-1];
wire a_lap      = a_lag[ROT_Y-1];
// except for the first ROT_Y beats of a lap: there the operand is the tail of the
// word that the PREVIOUS lap wrote into the ring, and those bits never left the
// ring, so the wrap shadow holds the injected values of the last ROT_Y beats.
wire y_back     = (pos < ROT_Y) ? ywr[pos[1:0]] : y_lap;
wire a_back     = (pos < ROT_Y) ? awr[pos[1:0]] : a_lap;
// round keys, one bit per beat: the block round takes k = A (guide section 7,
// Speck128128EncryptExpandKey), and A_old[p] is exactly the bit leaving aq now.
// The schedule step takes k = the step index, a 64-bit word whose only possibly
// set bits are the low IDX_BITS of sched_cnt, so positions above that are 0.
wire rk_bit     = a_out;
wire idx_bit    = (pos < IDX_BITS[POS_BITS-1:0]) ? sched_cnt[pos[2:0]] : 1'b0;

wire x_sum      = x_fwd ^ y_out ^ carry_x ^ rk_bit;
wire x_carry    = (x_fwd & y_out) | (carry_x & (x_fwd ^ y_out));
wire y_sum      = y_back ^ x_sum;               // ER64 uses the NEW x
wire b_sum      = b_fwd ^ a_out ^ carry_b ^ idx_bit;
wire b_carry    = (b_fwd & a_out) | (carry_b & (b_fwd ^ a_out));
wire a_sum      = a_back ^ b_sum;               // ER64 uses the NEW b

// a scored lap is any busy lap except the aligning one
wire running    = busy & ~aligning;
// the align lap recirculates: it must not apply a round, it only primes the
// shadow and the delay lines with the words that were just loaded
wire x_ins      = in_load ? (dst_x ? ld_bit : x_out) : (running ? x_sum : x_out);
wire y_ins      = in_load ? (dst_y ? ld_bit : y_out) : (running ? y_sum : y_out);
wire a_ins      = in_load ? (dst_a ? ld_bit : a_out) : (running ? a_sum : a_out);
wire b_ins      = in_load ? (dst_b ? ld_bit : b_out) : (running ? b_sum : b_out);

// ---- lap and round sequencing --------------------------------------------------
wire lap_end    = (pos == LAST_POS);
wire round_end  = lap_end & running;
wire sched_end  = round_end & (round_cnt < (ROUNDS[IDX_BITS-1:0] - 1'd1));
wire round_last = round_end & (round_cnt == (ROUNDS[IDX_BITS-1:0] - 1'd1));
// the very last bit of the last accepted word closes the load
wire ld_last    = (ld_rem == 3'd1) & ~word_in & ~streams_open;
wire capture    = lap_end & (running | (in_load & ld_last & ~busy));
wire load_close = ld_last & ~word_in & lap_end;

// run is only granted on a free bus with every accepted word fully serialised,
// because a run request that lands inside a word would truncate that word
wire run_evt    = run_req & ~busy & ~done & ~start;
wire run_ready  = ~mid_word & ~streams_open & (key_cnt == LOAD_WORDS[3:0]) &
                  (blk_cnt == LOAD_WORDS[3:0]);
wire run_bad    = run_evt & ~(run_ready & (err_code == ERR_NONE));
wire run_go     = run_evt & ~run_bad;

wire [2:0] new_err =
      mix_req  ? ERR_MIXED :
      kw_ovf   ? ERR_KWORD :
      bw_ovf   ? ERR_BWORD :
      late_evt ? ERR_LATE  :
      run_bad  ? ERR_SHORT : ERR_NONE;
wire latch_err = (new_err != ERR_NONE) & (err_code == ERR_NONE);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        xq        <= {WORD_BITS{1'b0}};
        yq        <= {WORD_BITS{1'b0}};
        aq        <= {WORD_BITS{1'b0}};
        bq        <= {WORD_BITS{1'b0}};
        ctx_r     <= {WORD_BITS{1'b0}};
        cty_r     <= {WORD_BITS{1'b0}};
        xsh       <= {SHDW{1'b0}};
        bsh       <= {SHDW{1'b0}};
        ywr       <= {ROT_Y{1'b0}};
        awr       <= {ROT_Y{1'b0}};
        y_lag     <= {LAGW{1'b0}};
        a_lag     <= {LAGW{1'b0}};
        ld_sr     <= {BUS_BITS{1'b0}};
        ld_rem    <= {LDBITS{1'b0}};
        pos       <= {POS_BITS{1'b0}};
        carry_x   <= 1'b0;
        carry_b   <= 1'b0;
        ld_key    <= 1'b0;
        ld_hi     <= 1'b0;
        aligning  <= 1'b0;
        run_pend  <= 1'b0;
        ld_done   <= 1'b0;
        round_cnt <= {IDX_BITS{1'b0}};
        sched_cnt <= {IDX_BITS{1'b0}};
        key_cnt   <= 4'h0;
        blk_cnt   <= 4'h0;
        err_code  <= ERR_NONE;
        done      <= 1'b0;
        busy      <= 1'b0;
    end else if (clk_en) begin
        if (start) begin
            pos       <= {POS_BITS{1'b0}};
            ld_rem    <= {LDBITS{1'b0}};
            round_cnt <= {IDX_BITS{1'b0}};
            sched_cnt <= {IDX_BITS{1'b0}};
            key_cnt   <= 4'h0;
            blk_cnt   <= 4'h0;
            carry_x   <= 1'b0;
            carry_b   <= 1'b0;
            aligning  <= 1'b0;
            run_pend  <= 1'b0;
            ld_done   <= 1'b0;
            err_code  <= (kw_valid | bw_valid | run_req) ? ERR_LATE : ERR_NONE;
            done      <= 1'b0;
            busy      <= 1'b0;
        end else begin
            if (latch_err) err_code <= new_err;

            if (word_in) begin
                ld_rem <= LAST_BIT;               // BUS_BITS-1 bits still to inject
                ld_sr  <= {1'b0, ld_word[BUS_BITS-1:1]};
                ld_key <= kw_acc;
                ld_hi  <= (kw_acc ? key_cnt : blk_cnt) >= (LOAD_WORDS[3:0] / 2);
                if (kw_acc) key_cnt <= key_cnt + 4'h1;
                if (bw_acc) blk_cnt <= blk_cnt + 4'h1;
            end else if (mid_word) begin
                ld_rem <= ld_rem - 3'd1;
                ld_sr  <= {1'b0, ld_sr[BUS_BITS-1:1]};
            end

            if (in_load | busy) begin
                // the rings circulate one bit per beat; pos names the bit slot
                if (pos != LAST_POS) pos <= pos + 3'd1;
                else                 pos <= {POS_BITS{1'b0}};

                xq <= {x_ins, xq[WORD_BITS-1:1]};
                yq <= {y_ins, yq[WORD_BITS-1:1]};
                aq <= {a_ins, aq[WORD_BITS-1:1]};
                bq <= {b_ins, bq[WORD_BITS-1:1]};

                y_lag <= {y_lag[LAGW-2:0], y_out};
                a_lag <= {a_lag[LAGW-2:0], a_out};

                if (pos < ROT_X) begin
                    xsh[pos[2:0]] <= x_out;
                    bsh[pos[2:0]] <= b_out;
                end

                // the last ROT_Y beats of a lap hand their freshly written bits to
                // the rotate-left taps of the next lap's first beats
                if (pos >= WRAP_START) begin
                    ywr <= {y_ins, ywr[ROT_Y-1:1]};
                    awr <= {a_ins, awr[ROT_Y-1:1]};
                end

                // the carry ripples upwards through the lap and restarts at the
                // lap boundary, so it must be cleared on the LAST beat: by the time
                // pos is 0 the adder needs to already see carry in = 0
                carry_x <= (pos == LAST_POS) ? 1'b0 : x_carry;
                carry_b <= (pos == LAST_POS) ? 1'b0 : b_carry;

                if (capture) begin
                    ctx_r <= {x_ins, xq[WORD_BITS-1:1]};
                    cty_r <= {y_ins, yq[WORD_BITS-1:1]};
                end

                if (lap_end) begin
                    // the align lap is closed outside the running test, because an
                    // aligning lap is by definition not running
                    if (aligning) begin
                        aligning <= 1'b0;
                    end
                    else if (busy) begin
                        round_cnt <= round_cnt + 3'h1;
                        if (sched_end) sched_cnt <= sched_cnt + 3'h1;
                        if (round_last) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                        end
                    end
                end
            end

            if (load_close) ld_done <= 1'b1;

            // an accepted run only arms the engine: pos and ld_rem are already at
            // the lap boundary because run_ready demanded a drained load pipeline
            if (run_go) run_pend <= 1'b1;
            else if (run_bad) done <= 1'b1;

            // an accepted run opens the align lap on the first free beat
            if (run_pend & ~busy & (ld_rem == {LDBITS{1'b0}})) begin
                busy     <= 1'b1;
                run_pend <= 1'b0;
                aligning <= 1'b1;
            end
        end
    end
end

endmodule
