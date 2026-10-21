// ============================================================================
// can_ctrl -- CAN 2.0A controller (11-bit standard identifier frames).
//
// Single-shot TX engine (SOF, ID, RTR, IDE/r0, DLC, 0..8 data bytes, CRC15,
// bit stuffing, ACK-slot check, EOF) plus an RX engine (SOF hard-sync,
// de-stuff, CRC15 check, dominant ACK drive). An internal wired-AND loopback
// (tx_wire & rx drive) feeds the receiver for selftest.
//
// Bit timing: each bit = 1 (SYNC) + SEG1 + SEG2 time quanta; one tq = TQ_DIV
// clk_en beats. Sample point is at the end of SEG1.
//
// Logical (destuffed) bit layout, position lpos:
//   0              SOF (dominant 0)
//   1..11          ID[10:0] MSB first
//   12             RTR
//   13..14         IDE=0, r0=0
//   15..18         DLC[3:0] MSB first
//   19..19+ndb-1   data bits (byte0 MSB first; ndb = rtr ? 0 : 8*dlc)
//   ..+15          CRC15[14:0] MSB first          (end of stuffed region)
//   ..             CRC delim=1, ACK slot, ACK delim=1, EOF = 7 recessive
//
// Bit stuffing applies SOF..CRC-seq inclusive; a run of 5 completing on the
// last CRC bit still inserts a stuff bit ahead of the CRC delimiter.
// All registers clk_en gated. drive levels: 1 = recessive, 0 = dominant.
// ============================================================================
module can_ctrl #(
    parameter integer TQ_DIV = 4,   // clk_en ticks per time quantum
    parameter integer SEG1   = 4,   // prop-seg + phase-seg1 (tq)
    parameter integer SEG2   = 2    // phase-seg2 (tq)
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    // bus side (recessive = 1, dominant = 0)
    input  wire        rx_pin,      // external receive input
    output wire        tx_pin,      // transmit drive output
    input  wire        loopback,    // 1: receiver listens to internal wire
    // TX command
    input  wire        tx_req,      // 1 clk_en pulse while !tx_busy
    input  wire [10:0] tx_id,
    input  wire        tx_rtr,
    input  wire [3:0]  tx_dlc,
    input  wire [63:0] tx_data,     // byte0 at [63:56], sent MSB first
    output reg         tx_busy,
    output reg         tx_done,     // 1 clk_en pulse at end of frame
    output reg         tx_ack,      // frame was acknowledged on the wire
    // RX monitor / result
    output reg         rx_mon_v,    // strobe: one wire bit sampled (incl stuff)
    output reg         rx_mon_b,
    output reg         rx_frm_v,    // strobe: frame complete, results valid
    output reg         rx_busy,     // a frame is on the wire
    output reg  [10:0] rx_id,
    output reg         rx_rtr,
    output reg  [3:0]  rx_dlc,
    output reg  [63:0] rx_data,     // right-justified; byte0 = [8*dlc-1 -: 8]
    output reg  [14:0] rx_crc,      // received CRC field
    output reg         rx_crc_ok,
    output reg         rx_stuff_err,
    output reg         rx_form_err
);

localparam integer TQB = 1 + SEG1 + SEG2;                 // tq per bit
localparam integer PW  = (TQ_DIV <= 1) ? 1 : $clog2(TQ_DIV);
localparam integer TQW = (TQB   <= 1) ? 1 : $clog2(TQB);

// ---------------------------------------------------------------------------
// CAN CRC15, poly x^15+x^14+x^10+x^8+x^7+x^4+x^3+1 (0x4599), serial MSB-first
// ---------------------------------------------------------------------------
function [14:0] crc15;
    input [14:0] c;
    input        b;
    reg          fb;
    begin
        fb    = b ^ c[14];
        crc15 = {c[13:0], 1'b0} ^ (fb ? 15'h4599 : 15'h0000);
    end
endfunction

// ---------------------------------------------------------------------------
// shared wire: in loopback the bus is wired-AND of TX drive and RX ACK drive
// (declarations below; the assign sits after tx_wire is declared)
// ---------------------------------------------------------------------------
reg  rdrv;                          // rx drive: 0 during ACK slot

// ===========================================================================
// TX engine
// ===========================================================================
reg [10:0] tid;
reg        trtr;
reg [3:0]  tdlc;
reg [63:0] tdata;
reg [6:0]  ndb;                     // data bits in frame (0..64)
reg [6:0]  lpos;                    // next logical bit index
reg [6:0]  lend;                    // total logical bits = 44 + ndb
reg [14:0] ccrc;                    // running CRC over destuffed bits
reg [14:0] tcrc;                    // CRC shift-out register
reg [2:0]  run_len;                 // consecutive equal stuffed-region bits
reg        last_db;
reg        tx_wire;
reg        finishing;
reg [PW-1:0]  tpre;
reg [TQW-1:0] ttq;
reg        cur_lbit;

wire [14:0] ccrc_n = crc15(ccrc, cur_lbit);
wire tq_last = (tpre == TQ_DIV-1);
wire t_bnd   = tq_last && (ttq == TQB-1);       // wire bit boundary
wire t_smp   = tq_last && (ttq == SEG1);        // tx sample point (ACK check)

always @(*) begin
    if      (lpos == 7'd0)        cur_lbit = 1'b0;                    // SOF
    else if (lpos <  7'd12)       cur_lbit = tid[7'd11 - lpos];       // ID
    else if (lpos == 7'd12)       cur_lbit = trtr;                    // RTR
    else if (lpos <  7'd15)       cur_lbit = 1'b0;                    // IDE,r0
    else if (lpos <  7'd19)       cur_lbit = tdlc[7'd18 - lpos];      // DLC
    else if (lpos <  7'd19 + ndb) cur_lbit = tdata[7'd63 - (lpos - 7'd19)];
    else if (lpos <  7'd34 + ndb) cur_lbit = tcrc[14];                // CRC out
    else                          cur_lbit = 1'b1;                    // CDEL..EOF
end

assign tx_pin = tx_wire;

// wired-AND loopback bus: 1 recessive, 0 dominant
wire bus = loopback ? (tx_wire & rdrv) : rx_pin;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_busy <= 1'b0; tx_done <= 1'b0; tx_ack <= 1'b0;
        tx_wire <= 1'b1; finishing <= 1'b0;
        tpre <= {PW{1'b0}}; ttq <= {TQW{1'b0}};
        tid <= 11'd0; trtr <= 1'b0; tdlc <= 4'd0; tdata <= 64'd0;
        ndb <= 7'd0; lpos <= 7'd0; lend <= 7'd44;
        ccrc <= 15'd0; tcrc <= 15'd0;
        run_len <= 3'd0; last_db <= 1'b0;
    end else if (clk_en) begin
        tx_done <= 1'b0;
        if (!tx_busy) begin
            if (tx_req) begin
                tx_busy <= 1'b1;
                tid   <= tx_id;  trtr <= tx_rtr;
                tdlc  <= tx_dlc; tdata <= tx_data;
                ndb   <= tx_rtr ? 7'd0 : {tx_dlc, 3'b000};
                lend  <= 7'd44 + (tx_rtr ? 7'd0 : {tx_dlc, 3'b000});
                // emit SOF (lpos=0) as the first wire bit right now
                tx_wire   <= 1'b0;
                lpos      <= 7'd1;
                run_len   <= 3'd1;
                last_db   <= 1'b0;
                ccrc      <= 15'd0;              // crc15(0,SOF=0) = 0
                tcrc      <= 15'd0;
                finishing <= 1'b0;
                tx_ack    <= 1'b0;
                tpre      <= {PW{1'b0}};
                ttq       <= {TQW{1'b0}};
            end
        end else begin
            // time-quanta counters
            if (tq_last) begin
                tpre <= {PW{1'b0}};
                if (ttq == TQB-1) ttq <= {TQW{1'b0}};
                else              ttq <= ttq + 1'b1;
            end else tpre <= tpre + 1'b1;

            // ACK slot is on the wire while lpos == 36+ndb (already emitted)
            if (t_smp && (lpos == ndb + 7'd36))
                tx_ack <= ~bus;

            if (t_bnd) begin
                if (finishing) begin
                    tx_busy   <= 1'b0;
                    tx_done   <= 1'b1;
                    tx_wire   <= 1'b1;
                    finishing <= 1'b0;
                end else if (run_len == 3'd5) begin
                    tx_wire <= ~last_db;          // stuff bit, no consume
                    run_len <= 3'd0;
                end else begin
                    tx_wire <= cur_lbit;
                    if (lpos < ndb + 7'd34) begin // stuffed region
                        if (run_len != 3'd0 && cur_lbit == last_db)
                            run_len <= run_len + 3'd1;
                        else run_len <= 3'd1;
                        last_db <= cur_lbit;
                    end else run_len <= 3'd0;
                    if (lpos < ndb + 7'd19) ccrc <= ccrc_n;
                    if (lpos == ndb + 7'd18) tcrc <= ccrc_n;
                    if (lpos >= ndb + 7'd19 && lpos < ndb + 7'd34)
                        tcrc <= {tcrc[13:0], 1'b0};
                    if (lpos == lend - 7'd1) finishing <= 1'b1;
                    lpos <= lpos + 7'd1;
                end
            end
        end
    end
end

// ===========================================================================
// RX engine
// ===========================================================================
localparam [3:0] RS_IDLE = 4'd0,  RS_SOF  = 4'd1,  RS_ID   = 4'd2,
                 RS_RTR  = 4'd3,  RS_CTRL = 4'd4,  RS_DLC  = 4'd5,
                 RS_DATA = 4'd6,  RS_CRC  = 4'd7,  RS_CDEL = 4'd8,
                 RS_ACK  = 4'd9,  RS_ADEL = 4'd10, RS_EOF  = 4'd11;

reg [3:0]  rs;
reg [6:0]  rcnt;                    // bit index inside current field
reg [6:0]  rndb;                    // expected data bits this frame
reg [2:0]  rrun;                    // consecutive equal destuffed bits
reg        rlast;
reg [14:0] rcrc;                    // CRC accumulator
reg [14:0] rcrc_in;                 // received CRC shift register
reg        ack_pend, ack_on;
reg [PW-1:0]  rpre;
reg [TQW-1:0] rtq;
reg        bus_d;

wire r_smp = rx_busy && (rpre == TQ_DIV-1) && (rtq == SEG1);
wire r_bnd = rx_busy && (rpre == TQ_DIV-1) && (rtq == TQB-1);
wire expect_stuff = (rrun == 3'd5) && (rs <= RS_CDEL);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rs <= RS_IDLE; rpre <= {PW{1'b0}}; rtq <= {TQW{1'b0}};
        rcnt <= 7'd0; rndb <= 7'd0; rrun <= 3'd0; rlast <= 1'b0;
        rcrc <= 15'd0; rcrc_in <= 15'd0;
        rdrv <= 1'b1; ack_pend <= 1'b0; ack_on <= 1'b0; bus_d <= 1'b1;
        rx_busy <= 1'b0; rx_mon_v <= 1'b0; rx_mon_b <= 1'b0; rx_frm_v <= 1'b0;
        rx_id <= 11'd0; rx_rtr <= 1'b0; rx_dlc <= 4'd0; rx_data <= 64'd0;
        rx_crc <= 15'd0; rx_crc_ok <= 1'b0;
        rx_stuff_err <= 1'b0; rx_form_err <= 1'b0;
    end else if (clk_en) begin
        rx_mon_v <= 1'b0;
        rx_frm_v <= 1'b0;
        bus_d    <= bus;

        // hard sync on the SOF falling edge while idle
        if (!rx_busy && bus_d && !bus) begin
            rx_busy <= 1'b1;
            rs      <= RS_SOF;
            rpre    <= {PW{1'b0}};
            rtq     <= {TQW{1'b0}};
            rcnt    <= 7'd0;
            rrun    <= 3'd0;
            rlast   <= 1'b0;
            rcrc    <= 15'd0;
            rcrc_in <= 15'd0;
            rx_id   <= 11'd0;
            rx_rtr  <= 1'b0;
            rx_dlc  <= 4'd0;
            rx_data <= 64'd0;
            rx_crc_ok    <= 1'b0;
            rx_stuff_err <= 1'b0;
            rx_form_err  <= 1'b0;
            rdrv    <= 1'b1;
            ack_pend <= 1'b0;
            ack_on   <= 1'b0;
        end else if (rx_busy) begin
            // tq counters
            if (rpre == TQ_DIV-1) begin
                rpre <= {PW{1'b0}};
                if (rtq == TQB-1) rtq <= {TQW{1'b0}};
                else              rtq <= rtq + 1'b1;
            end else rpre <= rpre + 1'b1;

            // dominant ACK drive covering one whole bit period
            if (r_bnd) begin
                if (ack_pend) begin
                    rdrv     <= 1'b0;
                    ack_on   <= 1'b1;
                    ack_pend <= 1'b0;
                end else if (ack_on) begin
                    rdrv   <= 1'b1;
                    ack_on <= 1'b0;
                end
            end

            if (r_smp) begin
                rx_mon_v <= 1'b1;
                rx_mon_b <= bus;
                if (expect_stuff) begin
                    if (bus == rlast) rx_stuff_err <= 1'b1;
                    rrun <= 3'd0;
                end else begin
                    // consume one destuffed bit
                    if (rs <= RS_CRC) begin
                        if (rrun != 3'd0 && bus == rlast)
                            rrun <= rrun + 3'd1;
                        else rrun <= 3'd1;
                        rlast <= bus;
                    end else rrun <= 3'd0;
                    if (rs < RS_CRC) rcrc <= crc15(rcrc, bus);
                    case (rs)
                        RS_SOF: begin
                            if (bus != 1'b0) rx_form_err <= 1'b1;
                            rs   <= RS_ID;
                            rcnt <= 7'd0;
                        end
                        RS_ID: begin
                            rx_id <= {rx_id[9:0], bus};
                            if (rcnt == 7'd10) begin
                                rs   <= RS_RTR;
                                rcnt <= 7'd0;
                            end else rcnt <= rcnt + 7'd1;
                        end
                        RS_RTR: begin
                            rx_rtr <= bus;
                            rs     <= RS_CTRL;
                            rcnt   <= 7'd0;
                        end
                        RS_CTRL: begin
                            if (rcnt == 7'd0 && bus != 1'b0)
                                rx_form_err <= 1'b1;    // IDE must be 0
                            if (rcnt == 7'd1) begin
                                rs   <= RS_DLC;
                                rcnt <= 7'd0;
                            end else rcnt <= rcnt + 7'd1;
                        end
                        RS_DLC: begin
                            rx_dlc <= {rx_dlc[2:0], bus};
                            if (rcnt == 7'd3) begin
                                rndb <= {rx_dlc[2:0], bus, 3'b000};
                                rs   <= (rx_rtr ||
                                        ({rx_dlc[2:0], bus} == 4'd0)) ?
                                        RS_CRC : RS_DATA;
                                rcnt <= 7'd0;
                            end else rcnt <= rcnt + 7'd1;
                        end
                        RS_DATA: begin
                            rx_data <= {rx_data[62:0], bus};
                            if (rcnt == rndb - 7'd1) begin
                                rs   <= RS_CRC;
                                rcnt <= 7'd0;
                            end else rcnt <= rcnt + 7'd1;
                        end
                        RS_CRC: begin
                            rcrc_in <= {rcrc_in[13:0], bus};
                            if (rcnt == 7'd14) begin
                                rs   <= RS_CDEL;
                                rcnt <= 7'd0;
                            end else rcnt <= rcnt + 7'd1;
                        end
                        RS_CDEL: begin
                            if (bus != 1'b1) rx_form_err <= 1'b1;
                            rx_crc    <= rcrc_in;
                            rx_crc_ok <= (rcrc == rcrc_in);
                            ack_pend  <= 1'b1;
                            rs        <= RS_ACK;
                        end
                        RS_ACK: rs <= RS_ADEL;
                        RS_ADEL: begin
                            if (bus != 1'b1) rx_form_err <= 1'b1;
                            rs   <= RS_EOF;
                            rcnt <= 7'd0;
                        end
                        RS_EOF: begin
                            if (bus != 1'b1) rx_form_err <= 1'b1;
                            if (rcnt == 7'd6) begin
                                rx_frm_v <= 1'b1;
                                rx_busy  <= 1'b0;
                                rs       <= RS_IDLE;
                            end else rcnt <= rcnt + 7'd1;
                        end
                        default: rs <= RS_IDLE;
                    endcase
                end
            end
        end
    end
end

endmodule
