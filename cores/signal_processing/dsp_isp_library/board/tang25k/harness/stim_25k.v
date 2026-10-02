// On-chip BLK1/IMG1 packet source for the Tang Primer 25K dock.
//
// The dock's BL702 USB-UART bridge does not drive pad B3: no echo came back, the
// beacon ramp never paused while the host transmitted, and a baud-independent pad
// loopback matched only by coincidence (24 bursts across all four DTR/RTS states
// produced no pad event).  So the stimulus is generated in the fabric and handed
// to the harness's own uart_rx as a real 115200 waveform; only the FPGA->host
// direction carries evidence.
//
// Frozen and untouched: packet framing, harness FSM, report format, numerical
// oracles.  Re-specified here: the payload *data*, from the LFSR below, mirrored
// word-for-word by rom_stim_25k.py, which is what the host feeds to
// protocol.verify().  tb_rom_harness_25k.sv decodes the emitted packet stream and
// compares it against that mirror, so RTL/mirror drift fails before silicon.
//
// Packet i seeds from SEED + i*32'h9E3779B9.  Per word index j exactly three
// draws are consumed whichever shape is chosen, so the sequence never depends on
// the shape:
//   SHAPE_PATTERN (0): word = {0x0000,0x8000,0x7FFF,0x03E8}[j & 3]
//   SHAPE_SINGLE  (1): word = draw1 & MASK
//   SHAPE_DOUBLE  (2): word = (draw1 & MASK) | ((draw2 & MASK) << SHIFT),
//                       replaced by (draw3 & 3) when IMP and (j % 7) == 0
module stim_25k #(
    parameter integer CLK_FRE = 50,
    parameter integer BAUD = 115200,
    // Bytes one case word occupies in the packet payload.  The 32-bit-word
    // harnesses (BLK1/IMG1) use 4; the DC -> statistics chain takes 16-bit
    // samples, so 2.  Everything below derives from it; 4 reproduces the
    // original expressions exactly.
    parameter integer BPE = 4,
    parameter [31:0] SEED = 32'HA5A5_1234,
    parameter [31:0] MAGIC = "BLK1",
    parameter integer NCASE = 4
) (
    input wire clk, rst_n,
    input wire report_line,          // harness uart_tx pad
    output wire tx_pin,              // bytes into the harness uart_rx
    output reg done);

localparam integer BITCYC = CLK_FRE * 1000000 / BAUD;
localparam integer GAPCYC = BITCYC / 8;
// log2 of the bytes-per-word selector, so the packet geometry below reads the
// same way for the 32-bit harnesses (BPESH=2) and for the 16-bit chain (BPESH=1).
localparam integer BPESH = (BPE == 2) ? 1 : 2;
// End-of-report has to be measured in byte times, not bit times: two 0x00 bytes
// in a row put no falling edge between them, so the report line can stay high for
// a whole byte mid-report.  Three byte times of silence is the safe floor.
localparam integer QUIET = BITCYC * 30;
localparam integer NOREPORT = CLK_FRE * 100000;
localparam integer STARTUP = 32768;           // outlasts the harness POR

localparam [1:0] PATTERN = 2'd0, SINGLE = 2'd1, DOUBLE = 2'd2;
localparam INIT = 3'd0, SEND = 3'd1, GAP = 3'd2, WAIT = 3'd3, FINISH = 3'd4;

reg [15:0] start_cnt;
reg [2:0] state;
reg [7:0] case_idx, gap_cnt, word_idx;
reg [8:0] byte_idx;
reg [31:0] lfsr, cur_word, seed_now;
reg [24:0] tmo;
reg [13:0] quiet;
reg seen_edge, tx_valid;

reg [31:0] d_tag, d_cfg, d_mask;
reg [7:0] d_count, d_stall;
reg [4:0] d_shift;
reg [1:0] d_shape;
reg d_imp;
`include "rom_desc.vh"

function [31:0] step32(input [31:0] s);
    reg fb;
    begin
        fb = s[31] ^ s[21] ^ s[1] ^ s[0];
        step32 = {s[30:0], fb};
    end
endfunction

// two-stage sync on the harness report pad
reg rl_meta = 1'b1, rl_sync = 1'b1;
always @(posedge clk) begin
    rl_meta <= report_line;
    rl_sync <= rl_meta;
end
wire rl_edge = rl_meta & ~rl_sync;

wire tx_ready;
wire byte_taken = tx_valid && tx_ready;

wire [9:0] total_bytes = 10'd14 + ({d_count, 2'b00} >> (2 - BPESH));
wire last_byte = (byte_idx == (total_bytes - 10'd1));
// the next byte starts a new word when (byte_idx+1) is 14 + BPE*j
wire word_head = (byte_idx >= 9'd13)
    && (((byte_idx - 9'd13) & (BPE - 1)) == 0) && !last_byte;
wire [7:0] next_widx = (byte_idx + 9'd1 - 9'd14) >> BPESH;
wire is_impulse = (next_widx == 8'd0) || (next_widx == 8'd7) || (next_widx == 8'd14)
    || (next_widx == 8'd21) || (next_widx == 8'd28) || (next_widx == 8'd35)
    || (next_widx == 8'd42) || (next_widx == 8'd49) || (next_widx == 8'd56)
    || (next_widx == 8'd63);
wire [31:0] pat_word = (next_widx[1] == 1'b0)
    ? (next_widx[0] ? 32'h0000_8000 : 32'h0000_0000)
    : (next_widx[0] ? 32'h0000_03E8 : 32'h0000_7FFF);

wire [31:0] n1 = step32(lfsr);
wire [31:0] n2 = step32(n1);
wire [31:0] n3 = step32(n2);
wire [31:0] drawn = (d_shape == PATTERN) ? pat_word
    : (d_shape == SINGLE) ? (n1 & d_mask)
    : (d_imp && is_impulse) ? (n3 & 32'h3)
    : ((n1 & d_mask) | ((n2 & d_mask) << d_shift));

wire [7:0] head_byte = (byte_idx == 9'd0) ? MAGIC[31:24]
    : (byte_idx == 9'd1) ? MAGIC[23:16]
    : (byte_idx == 9'd2) ? MAGIC[15:8]
    : (byte_idx == 9'd3) ? MAGIC[7:0]
    : (byte_idx < 9'd8)  ? d_tag >> (8 * (byte_idx - 9'd4))
    : (byte_idx < 9'd12) ? d_cfg >> (8 * (byte_idx - 9'd8))
    : (byte_idx == 9'd12) ? d_count
    : d_stall;
wire [8:0] payload_pos = byte_idx - 9'd14;
// byte lane inside the current word: [1:0] for 4-byte words, [0] for 2-byte ones
wire [1:0] lane = (BPESH == 2) ? payload_pos[1:0] : {1'b0, payload_pos[0]};
wire [7:0] byte_out = (byte_idx < 9'd14) ? head_byte
                                    : cur_word >> (8 * lane);

uart_tx #(.CLK_FRE(CLK_FRE), .BAUD_RATE(BAUD)) tx(
    .clk(clk), .rst_n(rst_n), .tx_data(byte_out), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(tx_pin), .tx_busy());

always @(posedge clk) begin
    if (!rst_n) begin
        start_cnt <= 0; state <= INIT; case_idx <= 0; gap_cnt <= 0;
        word_idx <= 0; byte_idx <= 0;
        lfsr <= SEED; seed_now <= SEED; cur_word <= 0;
        tx_valid <= 1'b0; done <= 1'b0; tmo <= 0; quiet <= 0;
        seen_edge <= 1'b0;
    end else begin
        if (rl_edge) begin
            quiet <= 0;
            if (state == WAIT) seen_edge <= 1'b1;
        end else if (quiet < QUIET[13:0]) quiet <= quiet + 1'b1;

        case (state)
            INIT: if (start_cnt >= STARTUP[15:0]) begin
                byte_idx <= 0; state <= SEND;
            end else if (!start_cnt[15]) start_cnt <= start_cnt + 1'b1;

            SEND: begin
                tx_valid <= 1'b1;
                if (byte_taken) begin
                    tx_valid <= 1'b0;
                    gap_cnt <= 0;
                    if (last_byte) begin
                        byte_idx <= 0;
                        seen_edge <= 1'b0; tmo <= 0; quiet <= 0;
                        state <= WAIT;
                    end else begin
                        byte_idx <= byte_idx + 1'b1;
                        state <= GAP;
                    end
                end
            end

            GAP: begin
                tx_valid <= 1'b0;
                if (gap_cnt >= GAPCYC[7:0]) state <= SEND;
                else gap_cnt <= gap_cnt + 1'b1;
            end

            WAIT: begin
                tx_valid <= 1'b0;
                if (tmo < NOREPORT[24:0]) tmo <= tmo + 1'b1;
                if ((seen_edge && quiet >= QUIET[13:0])
                        || tmo == NOREPORT[24:0]) begin
                    byte_idx <= 0; word_idx <= 0;
                    seen_edge <= 1'b0; tmo <= 0; quiet <= 0;
                    if (case_idx == (NCASE - 1)) begin
                        state <= FINISH; done <= 1'b1;
                    end else begin
                        case_idx <= case_idx + 1'b1;
                        seed_now <= seed_now + 32'h9E3779B9;
                        lfsr <= seed_now + 32'h9E3779B9;
                        state <= SEND;
                    end
                end
            end

            FINISH: begin
                tx_valid <= 1'b0;
                done <= 1'b1;
            end

            default: state <= INIT;
        endcase

        if (word_head && byte_taken) begin
            word_idx <= next_widx;
            cur_word <= drawn;
            lfsr <= n3;
        end
    end
end

endmodule
