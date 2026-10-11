`timescale 1ns / 1ps
// ips_trng_vonng_cond : entropy-source consumer with a von Neumann conditioner.
//
// One entropy sample is taken per enabled clock from an asynchronous, jittery and
// therefore metastable-prone pin through a SYNC_STAGES-deep shift synchroniser.
// Only the settled (last-stage) bit is consumed.  Settled bits are grouped into
// pairs: pair 01 emits a 1, pair 10 emits a 0, pairs 00 and 11 are discarded.
// bit_cnt accounts for every consumed settled bit, out_bit_cnt for every emitted
// bit and disc_pair_cnt for every discarded pair, so
//     bit_cnt == 2*(out_bit_cnt + disc_pair_cnt) + pair_pending
// holds after every enabled clock.  The watchdog counts settled bits that repeat
// the previous settled level; a run of STUCK_LIMIT of them raises stuck_alarm,
// which is sticky -- it only falls on cond_start or reset, never by itself when the
// input starts moving again.  cond_start restarts a conditioning run and clears the
// counters, the pairing state and the alarm.
// FUNCTIONAL PROTOTYPE ONLY: raw-noise conditioning policy only -- statistical
// quality of the entropy source, constant-time and side-channel leakage behaviour
// are NOT verified here and board evidence is DEFERRED.
module ips_trng_vonng_cond #(
    parameter CNT_BITS    = 12,
    parameter SYNC_STAGES = 2,
    parameter STUCK_LIMIT = 12'd64
)(
    input  wire                clk,
    input  wire                clk_en,
    input  wire                rst_n,

    input  wire                cond_start,
    input  wire                cond_run,
    input  wire                src_bit,

    output reg                 out_bit,
    output reg                 out_valid,
    output reg                 stuck_alarm,
    output reg                 pair_pending,
    output reg [CNT_BITS-1:0]  out_bit_cnt,
    output reg [CNT_BITS-1:0]  disc_pair_cnt,
    output reg [CNT_BITS-1:0]  bit_cnt
);

localparam [1:0] VONN_ONE  = 2'b01;
localparam [1:0] VONN_ZERO = 2'b10;

localparam [CNT_BITS-1:0] COUNT_STEP = 12'h0001;

reg [SYNC_STAGES-1:0]  sync_q;
reg [SYNC_STAGES-1:0]  val_q;
reg                    first_bit;
reg                    prev_ent;
reg [CNT_BITS-1:0]     wd;

wire ent_bit = sync_q[SYNC_STAGES-1];
wire ent_vld = val_q[SYNC_STAGES-1];

wire [1:0] pair      = {first_bit, ent_bit};
wire       pair_one  = (pair == VONN_ONE);
wire       pair_zero = (pair == VONN_ZERO);
wire       pair_full = ent_vld & pair_pending;
wire       pair_emit = pair_full & (pair_one | pair_zero);
wire       pair_drop = pair_full & ~(pair_one | pair_zero);

wire [CNT_BITS-1:0] wd_next = wd + COUNT_STEP;
wire [CNT_BITS-1:0] wd_cap  = (wd_next > STUCK_LIMIT) ? STUCK_LIMIT : wd_next;
wire same_level = ent_vld & (ent_bit == prev_ent);
wire alarm_now  = same_level & (wd_cap >= STUCK_LIMIT);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sync_q        <= {SYNC_STAGES{1'b0}};
        val_q         <= {SYNC_STAGES{1'b0}};
        first_bit     <= 1'b0;
        prev_ent      <= 1'b0;
        pair_pending  <= 1'b0;
        out_bit       <= 1'b0;
        out_valid     <= 1'b0;
        stuck_alarm   <= 1'b0;
        out_bit_cnt   <= {CNT_BITS{1'b0}};
        disc_pair_cnt <= {CNT_BITS{1'b0}};
        bit_cnt       <= {CNT_BITS{1'b0}};
        wd            <= {CNT_BITS{1'b0}};
    end else if (clk_en) begin
        out_valid <= 1'b0;

        if (cond_start) begin
            sync_q        <= {SYNC_STAGES{1'b0}};
            val_q         <= {SYNC_STAGES{1'b0}};
            first_bit     <= 1'b0;
            prev_ent      <= 1'b0;
            pair_pending  <= 1'b0;
            stuck_alarm   <= 1'b0;
            out_bit_cnt   <= {CNT_BITS{1'b0}};
            disc_pair_cnt <= {CNT_BITS{1'b0}};
            bit_cnt       <= {CNT_BITS{1'b0}};
            wd            <= {CNT_BITS{1'b0}};
        end else begin
            sync_q <= {sync_q[SYNC_STAGES-2:0], src_bit};
            val_q  <= {val_q[SYNC_STAGES-2:0], cond_run};

            if (ent_vld) begin
                bit_cnt <= bit_cnt + COUNT_STEP;

                if (!pair_pending) begin
                    first_bit    <= ent_bit;
                    pair_pending <= 1'b1;
                end else begin
                    pair_pending <= 1'b0;
                    if (pair_emit) begin
                        out_bit     <= pair_one;
                        out_valid   <= 1'b1;
                        out_bit_cnt <= out_bit_cnt + COUNT_STEP;
                    end else begin
                        disc_pair_cnt <= disc_pair_cnt + COUNT_STEP;
                    end
                end

                if (!same_level) wd <= {CNT_BITS{1'b0}};
                else begin
                    wd <= wd_cap;
                    if (alarm_now) stuck_alarm <= 1'b1;
                end

                prev_ent <= ent_bit;
            end
        end
    end
end

endmodule
