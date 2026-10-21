`timescale 1ns / 1ps
// ips_one_wire_master : 1-Wire (DS2490 / DS28EC01 style) master for the
// ip_series_20k production line.
//
// Board-free design: every slot edge is generated from an explicit `tick` input
// (the timing quantum, ~1 us in the intended 27 MHz configuration) instead of an
// on-chip oscillator, so models/ips_one_wire_master.py replays every drive window
// and every sampling decision cycle-exactly.  No board timing evidence is claimed.
//
// Bus model: the pad is open drain.  `ow_oe` high means the master is pulling the
// line low; `ow_i` is the pad input, high when nobody pulls.  The master never
// samples its own drive as data: the drive windows and the sample ticks below
// keep the sample instant inside the released part of every slot.
//
// Written contract (the golden model implements the same rules):
//   * commands are accepted only in S_IDLE, on a tick, and only one at a time:
//       cmd 2'd1 = reset + presence detect
//       cmd 2'd2 = write byte  (wdata, LSB first, one slot per bit)
//       cmd 2'd3 = read byte   (rx_word, LSB first, one slot per bit)
//     cmd 2'd0 asserted as a command is an invalid opcode: bad_cmd_sticky latches
//     and err_count steps, and the master stays idle.  cmd_valid while the master
//     is busy is a collision: busy_sticky latches, err_count steps and the command
//     is dropped.
//   * reset phase, tick index tc from 0: the master holds the line low while
//     tc < RST_LOW, releases it, samples the presence at tc == PRE_SMP
//     (presence = line low) and closes the phase at tc == PRE_END.  A high line at
//     the sample tick is a no-presence error: nopre_sticky latches, err_count
//     steps and presence reads 0.  A completed reset steps rst_count (saturating).
//   * slot phase, tick index tc from 0, one slot per bit, bit_idx 0..7, LSB first:
//       write slot: line low while tc < (tx_bit ? W1_LOW : W0_LOW)
//       read slot:  line low while tc < RD_LOW, sample pad at tc == RD_SMP
//                   (sampled high = 1, sampled low = 0), shift into rx_word
//     every slot ends at tc == SLOT_END.  The 8th slot (bit_idx == 3'd7) closes
//     the byte: done pulses for one tick and the master returns to S_IDLE.
//   * the RD_SMP tick is also the CRC feed tick.  With the command's crc_en
//     latched, the bit involved in the slot (the transmitted bit for a write slot,
//     the sampled pad level for a read slot) is clocked through the reflected
//     CRC-8 generator: crc <= (crc >> 1) ^ (crc[0] ^ bit ? CRC_POLY : 0), i.e. the
//     DS28EC01 polynomial x^8+x^5+x^4+1 written in reflected form 8'h8C.
//   * byte_count steps once per completed crc_en byte.  The command's crc_end flag
//     marks the byte that closes a scratchpad block: at that byte end the block is
//     checked.  A block must contain exactly CRC_BYTES crc_en bytes (8 data bytes
//     plus the CRC byte for the DS28EC01 scratchpad); otherwise len_sticky latches
//     and err_count steps.  If the length is right, the running CRC is the residue:
//     8'h00 means the block is good, anything else sets crc_sticky and steps
//     crc_count.  byte_count restarts at the block end, and the accumulator is
//     cleared when the first crc_en byte of the next block is launched, so the
//     residue itself stays readable on crc after the check.
//   * done is held while tick is low or clk_en is low: the whole engine freezes
//     between ticks and never free-runs against the clock.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).
module ips_one_wire_master #(
    parameter RST_LOW   = 6,
    parameter PRE_SMP   = 8,
    parameter PRE_END   = 12,
    parameter RD_LOW    = 2,
    parameter RD_SMP    = 3,
    parameter W1_LOW    = 2,
    parameter W0_LOW    = 6,
    parameter SLOT_END  = 5,
    parameter CRC_POLY  = 8'h8C,
    parameter CRC_BYTES = 9
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,

    input  wire       tick,
    input  wire       ow_i,
    input  wire [1:0] cmd,
    input  wire       cmd_valid,
    input  wire [7:0] wdata,
    input  wire       crc_en,
    input  wire       crc_end,

    output wire       ow_oe,
    output reg        done,
    output reg  [2:0] state,
    output reg  [5:0] tc,
    output reg  [2:0] bit_idx,
    output reg  [7:0] rx_word,
    output reg  [7:0] tx_word,
    output reg  [7:0] crc,
    output reg  [3:0] byte_count,
    output reg        presence,
    output reg        nopre_sticky,
    output reg        crc_sticky,
    output reg        len_sticky,
    output reg        busy_sticky,
    output reg        bad_cmd_sticky,
    output reg  [3:0] rst_count,
    output reg  [3:0] crc_count,
    output reg  [3:0] err_count
);

localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_RST  = 3'd1;
localparam [2:0] S_WBIT = 3'd2;
localparam [2:0] S_RBIT = 3'd3;
localparam [2:0] BIT_LAST = 3'd7;

reg crc_en_q;
reg crc_end_q;

wire smp     = (tc == RD_SMP);
wire smp_pre = (tc == PRE_SMP);
wire slot_e  = (tc == SLOT_END);
wire in_slot = (state == S_WBIT) || (state == S_RBIT);

// The bit the CRC generator sees in a slot: the driven bit for a write slot, the
// pad level for a read slot.
wire bit_now = (state == S_WBIT) ? tx_word[0] : ow_i;
wire crc_fb  = crc[0] ^ bit_now;
wire [7:0] crc_nx  = (crc >> 1) ^ (crc_fb ? CRC_POLY : 8'h00);
wire [3:0] bcnt_nx = byte_count + 4'd1;
wire [3:0] bcnt_blk = crc_en_q ? bcnt_nx : byte_count;

wire [31:0] low_len = (state == S_WBIT) ? (tx_word[0] ? W1_LOW : W0_LOW) : RD_LOW;

assign ow_oe = ((state == S_RST) && (tc < RST_LOW)) || (in_slot && (tc < low_len));

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done          <= 1'b0;
        state         <= S_IDLE;
        tc            <= 6'd0;
        bit_idx       <= 3'd0;
        rx_word       <= 8'h00;
        tx_word       <= 8'h00;
        crc           <= 8'h00;
        byte_count    <= 4'h0;
        presence      <= 1'b0;
        nopre_sticky  <= 1'b0;
        crc_sticky    <= 1'b0;
        len_sticky    <= 1'b0;
        busy_sticky   <= 1'b0;
        bad_cmd_sticky<= 1'b0;
        rst_count     <= 4'h0;
        crc_count     <= 4'h0;
        err_count     <= 4'h0;
        crc_en_q      <= 1'b0;
        crc_end_q     <= 1'b0;
    end else if (clk_en) begin
        if (tick) begin
            done <= 1'b0;
            if (cmd_valid && (state != S_IDLE)) begin
                busy_sticky <= 1'b1;
                if (err_count != 4'hF) begin
                    err_count <= err_count + 4'd1;
                end
            end
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        tc        <= 6'd0;
                        bit_idx   <= 3'd0;
                        crc_en_q  <= crc_en;
                        crc_end_q <= crc_end;
                        if (crc_en && (byte_count == 4'h0)) begin
                            crc <= 8'h00;
                        end
                        if (cmd == 2'd1) begin
                            state <= S_RST;
                        end else if (cmd == 2'd2) begin
                            state   <= S_WBIT;
                            tx_word <= wdata;
                        end else if (cmd == 2'd3) begin
                            state <= S_RBIT;
                        end else begin
                            bad_cmd_sticky <= 1'b1;
                            if (err_count != 4'hF) begin
                                err_count <= err_count + 4'd1;
                            end
                        end
                    end
                end
                S_RST: begin
                    if (smp_pre) begin
                        presence <= ~ow_i;
                        if (ow_i) begin
                            nopre_sticky <= 1'b1;
                            if (err_count != 4'hF) begin
                                err_count <= err_count + 4'd1;
                            end
                        end
                    end
                    if (tc == PRE_END) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                        if (rst_count != 4'hF) begin
                            rst_count <= rst_count + 4'd1;
                        end
                    end else begin
                        tc <= tc + 6'd1;
                    end
                end
                S_WBIT, S_RBIT: begin
                    if (smp) begin
                        if (state == S_RBIT) begin
                            rx_word <= {ow_i, rx_word[7:1]};
                        end
                        if (crc_en_q) begin
                            crc <= crc_nx;
                        end
                    end
                    if (slot_e) begin
                        if (state == S_WBIT) begin
                            tx_word <= {1'b0, tx_word[7:1]};
                        end
                        if (bit_idx == BIT_LAST) begin
                            state <= S_IDLE;
                            done  <= 1'b1;
                            if (crc_end_q) begin
                                if (bcnt_blk != CRC_BYTES) begin
                                    len_sticky <= 1'b1;
                                    if (err_count != 4'hF) begin
                                        err_count <= err_count + 4'd1;
                                    end
                                end else if (crc != 8'h00) begin
                                    crc_sticky <= 1'b1;
                                    if (crc_count != 4'hF) begin
                                        crc_count <= crc_count + 4'd1;
                                    end
                                end
                                byte_count <= 4'h0;
                            end else if (crc_en_q) begin
                                byte_count <= bcnt_nx;
                            end
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                            tc      <= 6'd0;
                        end
                    end else begin
                        tc <= tc + 6'd1;
                    end
                end
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end
end

endmodule
