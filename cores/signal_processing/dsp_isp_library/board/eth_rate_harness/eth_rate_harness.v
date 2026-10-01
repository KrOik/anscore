// Ethernet (100M RMII) board harness for dsp_isp_library rate-change cores.
//
// Same BLK2/RES2 block contract, canned configuration ROM and DUT wiring as
// board/dsp_rate_harness, which transports it over 115200-baud UART captured
// by an FX2 logic analyser at roughly 11.5 kB/s.  Here the transport is the
// dock's on-board LAN8720 RMII PHY behind rmii_eth_pipe, so a block leaves and
// returns as UDP datagrams at Ethernet rate and the per-block cycle counts
// become a real sustained-throughput measurement.
//
// Wire contract:
//   request  'BLK2' tag(4) config(4) in_count(1) stall(1) out_expect(1) rsvd(1)
//            + in_count * 32-bit words              (1 <= in_count <= 64)
//   request  'STA1'                                 (4 bytes)
//   reply    'RES2' tag(4) config(4) in_count(1) flags(1) inc(1) outc(1)
//            cycles(4) + 128 * 32-bit words; ALWAYS 532 bytes, bytes beyond
//            20 + 4*outc are zero padding
//   reply    'STAT' + 10 * 32-bit counters; ALWAYS 44 bytes
//
// flags: [0] malformed packet  [1] rx path error  [2] rx outside LOAD
//        [3] config rejected   [4] watchdog      [5] outc != out_expect
//        [6] output RAM overflow / capacity error [7] sticky output clip
//
// rsvd was a must-be-zero byte in the UART contract and is now a session
// control byte, still rejected above 3 so a typo cannot silently ask for
// persistence:
//   bit 0 PERSIST  -- do not reset the core before this block, so its filter
//       history / reference frame survives the block boundary, and do not
//       re-commit a configuration either.  Ignored until one block has been
//       configured successfully (there is nothing to persist yet), so the PERSIST
//       bit is harmless on the first block of a session.  Note the consequence:
//       a PERSIST block that also carries a NEW config_word keeps the OLD
//       settings -- RES2 still echoes the word the host sent, so the reply
//       reports what was asked for, not what the core is running.  Use bit 1 for
//       a block that must apply it.
//   bit 1 RECONFIG -- with PERSIST, keep the core's data state but assert
//       cfg_valid again, which is how a mid-session configuration change is
//       reached: the core sees no reset, only a new bundle.  Asking for it
//       without PERSIST (rsvd=2) is rejected, since "re-configure a core I am
//       about to reset" is just an ordinary block.
// A session is therefore block 0 with rsvd=0 (reset + configure) followed by
// rsvd=1 (continue) or rsvd=3 (continue with new settings).  An image built
// before this feature answers such a request with flags[0]=1, which is how the
// host tells an old bitstream from a session-capable one.
//
// Clocking: everything except MDC runs on the 50 MHz reference clock the PHY
// drives, so harness and Ethernet pipe share ONE clock domain and no
// unqualified async FIFO sits in the data path.  Reported cycles are 20 ns each,
// and for a core without a flush port they stop at the block's last handshake
// rather than at the end of the QUIET_MAX window that proves the core is done
// (see cycles_report), so they are usable as a throughput figure.  The 27 MHz
// board oscillator only feeds the PLL that makes 1 MHz MDC.
//
// CORE map, config ROM and word packing match dsp_rate_harness:
//   0 polyphase_resampler  1 halfband_decim  2 halfband_interp
//   3 ddc_stream           4 duc_stream      6 pfb_stream (M=8, P=8)
//   7 framediff_stream (4x4, 8-bit)  8 ccm_stream (Q2.13 matrix + PWL tone, 8-bit)
// The ISP core is carried here as well because the dock UART has no return
// path on this rig (measured: ttyUSB1 RX is empty at 4 baud rates, ttyUSB0 only
// echoes its own TX), so no IMR1 reply can ever reach the host:
//   5 median_stream (8x8, 8-bit, K=3) -- one block is one frame: in_count is
//     pinned to IMAGE_PIXELS by the parser, out_expect is always 64, and
//     config_word[0] selects the padding variant (0=ZERO, 1=REPLICATE).
//     Word packing is {21'b0, marker_error, eol, sof, pixel[7:0]}.
//   7 framediff_stream -- one block is ONE to FOUR 4x4 frames.  This core's only
//     stateful job is to difference against the PREVIOUS frame, so a single
//     block of 64 words (4*4*4, the same 64 words CORE 5 already spends) holds a
//     whole sequence without any transport help; with rsvd=1 the frames can also
//     be sent one block each and the reference RAM survives the boundary.
//     Word packing is {20'b0, scene_change, marker_error, eol, sof, pixel[7:0]}.
//   8 ccm_stream -- 1 RGB pixel word in, 1 out, so a block may be ANY length
//     1..64 and the block is about the matrix/tone arithmetic and the atomic
//     commit, not about raster structure.  config_word[3:0] selects a bundle and
//     the harness writes the core's whole 211-entry shadow image before it
//     commits, because ccm_stream validates the complete shadow at commit.
//     Word packing is {6'b0, eol, sof, pixel[23:0]}.
module eth_rate_harness #(parameter CORE = 0)(
    input wire clk,               // 27 MHz board oscillator
    input wire rst,                 // dock button, active-high (pull-up)
    input wire netrmii_clk50m,
    input wire netrmii_rx_crs,
    input wire [1:0] netrmii_rxd,
    output wire netrmii_mdc,
    output wire netrmii_txen,
    inout wire netrmii_mdio,
    output wire [1:0] netrmii_txd,
    output wire phyrst,
    output wire [5:0] led
);

localparam integer IN_CAP = 64;       // input store depth
localparam integer ETH_IN_CAP = 64;   // per-block limit of this transport
localparam integer OUT_CAP = 128;
localparam integer QUIET_MAX = 4095;
localparam integer RES_LEN = 532;     // 20 header + 128 result words
localparam integer STA_LEN = 44;      // 4 magic + 10 counters
// TXGO watchdog bound, generous against a 574-byte frame at 100M.
localparam integer TXGO_MAX = 32'd1000000;
localparam HAS_FLUSH = (CORE <= 2);
// CORE 5 is an image core: the window engine only produces a full frame once
// it has captured WIDTH*HEIGHT pixels, so a partial block has no defined
// output count and is rejected as malformed instead of guessed at.
localparam [7:0] IMAGE_PIXELS = 8'd64;     // 8 x 8, only used by CORE == 5
// CORE 7 is isp/framediff at a fixed 4x4 geometry.  FD_PIXELS is the block
// MAXIMUM: FOUR frames of 16 pixels.  A block may carry any whole number of
// frames up to that (count % 16 == 0), because a rsvd=1 PERSIST block leaves the
// core's reference RAM in place and the next block continues the sequence --
// 64 words without persistence, or one frame per block with it.  The raster
// markers the harness drives (SOF every 16 beats, EOL every 4) are what pin the
// geometry, so every fd_cfg bundle uses the same 4x4.
localparam [7:0] FD_PIXELS = 8'd64;
localparam integer FD_GW = 4;
localparam integer FD_GH = 4;

wire clk50m = netrmii_clk50m;
// The dock key pulls its pin to GND when pressed and the constraint file keeps
// an internal pull-up, so the pin idles HIGH and the running level is HIGH.
// This is the polarity the board-proven RSA top uses (.rst_n(rst)); inverting it
// here would hold the whole design in reset whenever nobody is touching the key.
wire btn_n = rst;

// ------------------------------------------------------------- clocks ------
wire clk1m, clk6m;
PLL_6M pll6m(.clkout(clk6m), .clkoutd(clk1m), .clkin(clk));

// ------------------------------------------------------------ pipe ---------
wire phy_ready;
wire rx_start, rx_valid, rx_end;
wire [7:0] rx_data;
wire [15:0] rx_index, rx_len;
wire [31:0] rx_src_ip;
wire [15:0] rx_src_port;

wire tx_wr;
wire [15:0] tx_wr_addr;
wire [7:0] tx_wr_data;
wire tx_req, tx_busy, tx_done;
wire [15:0] tx_len;
wire [31:0] tx_dst_ip;
wire [15:0] tx_dst_port;
wire [31:0] stat_rx_frames, stat_rx_udp, stat_ping, stat_tx_frames, stat_rx_err;

// Reply destination is latched from the datagram that asked for the reply, so
// the pipe sees a stable address through its two-cycle request arbitration.
reg [31:0] tx_dst_ip_r = 0;
reg [15:0] tx_dst_port_r = 0;
assign tx_dst_ip   = tx_dst_ip_r;
assign tx_dst_port = tx_dst_port_r;

// One-cycle tx_req pulse plus the completion matcher described at TXGO.
reg tx_req_p = 0;
reg [31:0] txgo_count = 0;
reg done_q = 0;
// FCS verdict of the frame that carried the block in flight; settles a few
// cycles after the last payload octet, long before RUN completes.
wire fcs_ok; wire pay_ok;
wire [215:0] dbg_frame;

rmii_eth_pipe #(
    .LOCAL_MAC(48'h0600AABB0CEE),
    .LOCAL_IP({8'd192, 8'd168, 8'd137, 8'd16}),
    .UDP_PORT(16'd11452),
    .TX_RAM_BYTES(640)
) pipe (
    .clk50m(clk50m), .clk1m(clk1m), .rst_n(btn_n),
    .rmii_rx_crs_dv(netrmii_rx_crs), .rmii_rxd(netrmii_rxd),
    .rmii_txd(netrmii_txd), .rmii_txen(netrmii_txen),
    .rmii_mdc(netrmii_mdc), .rmii_mdio(netrmii_mdio),
    .phy_rst(phyrst), .phy_ready(phy_ready),
    .rx_start(rx_start), .rx_valid(rx_valid), .rx_data(rx_data),
    .rx_index(rx_index), .rx_len(rx_len), .rx_end(rx_end),
    .rx_src_ip(rx_src_ip), .rx_src_port(rx_src_port),
    .tx_wr(tx_wr), .tx_wr_addr(tx_wr_addr), .tx_wr_data(tx_wr_data),
    .tx_req(tx_req), .tx_len(tx_len), .tx_dst_ip(tx_dst_ip),
    .tx_dst_port(tx_dst_port), .tx_busy(tx_busy), .tx_done(tx_done),
    .stat_rx_frames(stat_rx_frames), .stat_rx_udp(stat_rx_udp),
    .stat_ping(stat_ping), .stat_tx_frames(stat_tx_frames),
    .stat_rx_err(stat_rx_err), .fcs_ok(fcs_ok), .pay_ok(pay_ok),
    .dbg_frame(dbg_frame));

// Link-gated synchronous power-on reset for the harness itself.
reg [12:0] por = 0;
reg [1:0] rdy_sync = 0;
always @(posedge clk50m) begin
    rdy_sync <= {rdy_sync[0], phy_ready};
    if (!rdy_sync[1]) por <= 0;
    else if (!por[12]) por <= por + 1'b1;
end
wire rst_n = rdy_sync[1] && por[12] && btn_n;

localparam LOAD = 0, RESET = 1, CONFIG = 2, CHECK = 3, PREFETCH = 4, RUN = 5,
           HDRO = 6, RDW = 7, DATA = 8, SBYTE = 9, TXGO = 10, TRAIL = 11;
reg [3:0] state = LOAD;

reg [7:0] index, count, stall, flags, out_expect, rsvd_b;
reg [8:0] byte_index;
reg       dg_done;          // this datagram already replied / was consumed
wire [9:0] data_bytes = {count, 2'b00};
reg pers_b, rcfg_b;          // rsvd[0] PERSIST, rsvd[1] RECONFIG
reg [31:0] tag, config_word, assembly, cycles;
reg [31:0] last_act;         // cycles value on the last cycle the core did work
reg saw_act;
reg [6:0] input_count;
reg [7:0] output_count, read_index;
reg [2:0] phase;
reg [11:0] quiet;
reg flush_sent, drained;
// A core with no flush/drain port can only be known finished by the QUIET_MAX
// idle window, so its raw `cycles` always carries ~4095 cycles of transport
// tail.  Report the cycles up to and including the last cycle that carried an
// input or output handshake instead, which is the figure a throughput claim
// needs.  Flush cores end on drain -- every one of their cycles is real -- so
// they keep the raw count and their existing evidence stays comparable.
wire tail_stripped = !HAS_FLUSH && saw_act;
wire [31:0] cycles_report = tail_stripped ? (last_act + 32'd1) : cycles;
wire [31:0] input_q, output_q;

// Response construction.
reg mode_blk;          // 1 = RES2 block reply, 0 = STAT reply
reg reply_dbg;         // 1 = DBG2 diagnostic reply (same SBYTE path)
reg [15:0] wi;         // write address into the pipe TX RAM
reg [15:0] reply_len;
reg [6:0] rdw;         // result word index being emitted
reg [1:0] lane;        // byte lane of that word
// The ten reply words leave in a fixed order, so they ride a shift chain
// instead of ten registers behind a 10:1 read mux.  Loading is a permutation of
// wires and the emitting side always reads the top 32 bits, which is what took
// CORE 8 back inside the LUT budget (~290 MUX2 cells plus their fan-in).
reg [319:0] sr_chain;

assign tx_len = reply_len;
assign tx_req = tx_req_p;

// Cumulative counters for the STAT reply.
reg [31:0] cyc_total, words_in, words_out, blocks_done;
localparam [7:0] CORE_ID_B = CORE & 8'hFF;

// ---------------------------------------------------------------- DUT ------
wire in_ready, out_valid, cfg_ready, cfg_error, clip_w, cap_err, flush_rdy, flush_done;
wire [31:0] result;
wire in_valid = state == RUN && input_count < count;
wire out_ready = state == RUN && phase >= stall[2:0];
wire input_fire = in_valid && in_ready;
wire output_fire = out_valid && out_ready;
// PERSIST support: `configured` records that the core has completed at least one
// legal configuration since the board-level reset (rst_n).  It is cleared ONLY
// with rst_n, because the whole point of a session is that no per-block pulse
// touches the core.  cfg_skip marks the blocks that continue a session: the core
// sees no reset and CONFIG is stepped over, so cfg_valid cannot re-commit and
// drop the state the session is about.  A RECONFIG block keeps the data state
// but does re-enter CONFIG, which is the mid-session configuration change.
reg configured = 1'b0;
wire cfg_skip = pers_b && configured && !rcfg_b;
// Every persist block skips the reset pulse; only a plain persist also skips
// CONFIG, so RECONFIG reaches the core as a new bundle on an unreset core.
wire core_reset = rst_n && (state != RESET || (pers_b && configured));
wire inputs_done = input_count == count;
wire flush_req = HAS_FLUSH && state == RUN && inputs_done && !flush_sent && !drained;

`include "dsp_rate_harness_rom.vh"

// CORE 7 runtime bundles, one per config_word[3:0]:
//   {scpol, scn[7:0], alpha[3:0], thresh[7:0], mode[1:0]}
// Generated from FD_BUNDLES in dsp_rate_harness/protocol.py (fd_pack()), the
// same list the oracle runs, so the table the DUT commits cannot drift away
// from the table the host verifies against.
function [22:0] fd_cfg;
    input [3:0] sel;
begin
    case (sel)
      4'd0:  fd_cfg = 23'h201000;  // DIFF   thr 0  alpha 4 scn 128 pol RESET
      4'd1:  fd_cfg = 23'h201020;  // DIFF   thr 8  alpha 4 scn 128 pol RESET
      4'd2:  fd_cfg = 23'h201080;  // DIFF   thr 32 alpha 4 scn 128 pol RESET
      4'd3:  fd_cfg = 23'h200001;  // BG     thr 0  alpha 0 scn 128 pol RESET
      4'd4:  fd_cfg = 23'h200401;  // BG     thr 0  alpha 1 scn 128 pol RESET
      4'd5:  fd_cfg = 23'h201001;  // BG     thr 0  alpha 4 scn 128 pol RESET
      4'd6:  fd_cfg = 23'h201c01;  // BG     thr 0  alpha 7 scn 128 pol RESET
      4'd7:  fd_cfg = 23'h201002;  // MOTION thr 0  alpha 4 scn 128 pol RESET
      4'd8:  fd_cfg = 23'h201022;  // MOTION thr 8  alpha 4 scn 128 pol RESET
      4'd9:  fd_cfg = 23'h201082;  // MOTION thr 32 alpha 4 scn 128 pol RESET
      4'd10: fd_cfg = 23'h001040;  // DIFF   thr 16 alpha 4 scn 0   pol RESET
      4'd11: fd_cfg = 23'h401040;  // DIFF   thr 16 alpha 4 scn 0   pol FAST_ADAPT
      4'd12: fd_cfg = 23'h101001;  // BG     thr 0  alpha 4 scn 64  pol RESET
      4'd13: fd_cfg = 23'h501001;  // BG     thr 0  alpha 4 scn 64  pol FAST_ADAPT
      4'd14: fd_cfg = 23'h041022;  // MOTION thr 8  alpha 4 scn 16  pol RESET
      4'd15: fd_cfg = 23'h441022;  // MOTION thr 8  alpha 4 scn 16  pol FAST_ADAPT
      default: fd_cfg = 23'h201000;
    endcase
end
endfunction

// CORE 8 runtime bundles, one per config_word[3:0]:
//   {mp[2:0], bp, code0[1:0], code1[1:0], code2[1:0], tone0, tone1, tone2,
//    domain, 1'b0}  (bit0 is the pad, so every literal is even)
// Generated from CCM_BUNDLES in dsp_rate_harness/protocol.py (ccm_pack()), the
// same list the oracle runs, so the matrix / bias / tone banks the DUT commits
// cannot drift away from the banks the host verifies against.
function [15:0] ccm_cfg;
    input [3:0] sel;
begin
    case (sel)
      4'd0:  ccm_cfg = 16'h0000;  // identity,   no bias, no tone      (reset path)
      4'd1:  ccm_cfg = 16'h1000;  // gray-world, tone off
      4'd2:  ccm_cfg = 16'h2000;  // warm CCM, negative lobes
      4'd3:  ccm_cfg = 16'h3000;  // cross-mix, strongest negative lobes
      4'd4:  ccm_cfg = 16'h0800;  // identity + mixed-sign bias (8,4,-6)
      4'd5:  ccm_cfg = 16'h1210;  // gray-world, step curve on B, `lin`
      4'd6:  ccm_cfg = 16'h217e;  // warm, three curves, `enc` domain
      4'd7:  ccm_cfg = 16'h34fc;  // cross-mix, three curves, `lin` domain
      default: ccm_cfg = 16'h0000;
    endcase
end
endfunction

// Matrix presets, flat index k = row*3 + column (c00..c22).  Q2.13 signed; the
// 16-bit result is plain two's complement, so -2000 becomes 0xF830.  Every
// mixed-sign row sums |c| to at most 12192 < 7<<13 = 57344, so a commit of this
// table can never trip the core's per-row gain bound.
function [15:0] ccm_matrix;
    input [2:0] mp;
    input [3:0] k;
begin
    case (mp)
      3'd0: case (k)                      // identity (diagonal 1.0)
                4'd0, 4'd4, 4'd8: ccm_matrix = 8192;
                default:          ccm_matrix = 0;
            endcase
      3'd1: case (k)                      // gray-world
                4'd0, 4'd4, 4'd8: ccm_matrix = 6554;
                default:          ccm_matrix = 819;
            endcase
      3'd2: case (k)                      // warm: 10192 -2000 0 / -800 9008 0 / 0 -1600 9792
                4'd0: ccm_matrix = 10192;
                4'd1: ccm_matrix = -2000;
                4'd3: ccm_matrix = -800;
                4'd4: ccm_matrix = 9008;
                4'd7: ccm_matrix = -1600;
                4'd8: ccm_matrix = 9792;
                default: ccm_matrix = 0;
            endcase
      3'd3: case (k)                      // cross-mix
                4'd0: ccm_matrix = 6962;
                4'd1: ccm_matrix = 2458;
                4'd2: ccm_matrix = -1228;
                4'd3: ccm_matrix = -1228;
                4'd4: ccm_matrix = 11005;
                4'd5: ccm_matrix = -1585;
                4'd6: ccm_matrix = 2458;
                4'd7: ccm_matrix = -2867;
                4'd8: ccm_matrix = 8601;
            endcase
      default: ccm_matrix = (k == 4'd0 || k == 4'd4 || k == 4'd8) ? 8192 : 0;
    endcase
end
endfunction

// Bias presets, in pixel units (the core adds bias <<< 13 inside the row
// accumulator).  Signed; preset 1 is the mixed-sign case.
function [15:0] ccm_bias;
    input bp;
    input [1:0] k;
begin
    if (bp == 1'b0) ccm_bias = 0;
    else case (k)
      2'd0: ccm_bias = 8;
      2'd1: ccm_bias = 4;
      default: ccm_bias = -6;
    endcase
end
endfunction

// Tone node value for one channel's curve, node index i (0..32) of 32 uniform
// segments over [0,MPX] with MPX=255.  These are the same four curves
// ccm_curve() in protocol.py generates, written with 9-bit intermediates
// because i*8 reaches 256 at the last node:
//   0 identity (the core's reset default), 1 hard step at half scale,
//   2 lifted toe, 3 compressed shoulder.
function [7:0] ccm_node;
    input [1:0] code;
    input [5:0] i;
    reg [8:0] ramp, v;
begin
    ramp = {2'd0, i} * 9'd8;
    case (code)
      2'd0:    v = (i == 6'd32) ? 9'd255 : ramp;
      2'd1:    v = (i <  6'd16) ? 9'd0   : 9'd255;
      2'd2:    v = (ramp + 9'd24 > 9'd255) ? 9'd255 : (ramp + 9'd24);
      default: v = (ramp > 9'd127) ? 9'd127 : ramp;
    endcase
    ccm_node = (v > 9'd255) ? 8'd255 : v[7:0];
end
endfunction

generate
if (CORE == 0) begin: g_rs
  wire [2319:0] e = rs_cfg(config_word[3:0]);
  reg seen_done, seen_err; wire c_done, c_err;
  always @(posedge clk50m) begin
    if (!core_reset) begin seen_done <= 0; seen_err <= 0; end
    else begin if (c_done) seen_done <= 1; if (c_err) seen_err <= 1; end
  end
  wire bad = (|config_word[31:4]) || (config_word[3:0] > 5);
  wire signed [15:0] core_y;
  assign cfg_ready = seen_done | bad;
  assign cfg_error = seen_err | bad;
  assign result = {15'b0, clip_w, core_y};
  polyphase_resampler #(.MAX_TAPS(128), .MAX_INPUTS(65535)) core(
    .clk(clk50m), .rst_n(core_reset),
    .s_tdata(input_q[15:0]), .s_tvalid(in_valid), .s_tready(in_ready),
    .m_tdata(core_y), .m_tuser(clip_w), .m_tvalid(out_valid), .m_tready(out_ready),
    .cfg_valid(state == CONFIG && !bad), .cfg_ready(),
    .cfg_l(e[3:0]), .cfg_m(e[7:4]), .cfg_taps(e[15:8]), .cfg_coeffs(e[2319:16]),
    .cfg_done(c_done), .cfg_error(c_err),
    .flush_valid(flush_req), .flush_ready(flush_rdy), .flush_done(flush_done),
    .input_count(), .output_count(), .capacity_error(cap_err));
end else if (CORE == 1 || CORE == 2) begin: g_hb
  wire [167:0] e = hb_cfg(config_word[3:0]);
  reg seen_done, seen_err; wire c_done, c_err;
  always @(posedge clk50m) begin
    if (!core_reset) begin seen_done <= 0; seen_err <= 0; end
    else begin if (c_done) seen_done <= 1; if (c_err) seen_err <= 1; end
  end
  wire bad = (|config_word[31:4]) || (config_word[3:0] > 3);
  wire signed [15:0] core_y;
  assign cfg_ready = seen_done | bad;
  assign cfg_error = seen_err | bad;
  assign result = {15'b0, clip_w, core_y};
  if (CORE == 1) begin: b_decim
    halfband_decim #(.LANES(1)) core(.clk(clk50m), .rst_n(core_reset),
      .s_tdata(input_q[15:0]), .s_tvalid(in_valid), .s_tready(in_ready),
      .m_tdata(core_y), .m_tuser(clip_w), .m_tvalid(out_valid), .m_tready(out_ready),
      .cfg_valid(state == CONFIG && !bad), .cfg_ready(),
      .cfg_taps(e[5:0]), .cfg_coeffs(e[167:6]),
      .cfg_done(c_done), .cfg_error(c_err),
      .flush_valid(flush_req), .flush_ready(flush_rdy), .flush_done(flush_done),
      .input_count(), .output_count(), .capacity_error(cap_err));
  end else begin: b_interp
    halfband_interp #(.LANES(1)) core(.clk(clk50m), .rst_n(core_reset),
      .s_tdata(input_q[15:0]), .s_tvalid(in_valid), .s_tready(in_ready),
      .m_tdata(core_y), .m_tuser(clip_w), .m_tvalid(out_valid), .m_tready(out_ready),
      .cfg_valid(state == CONFIG && !bad), .cfg_ready(),
      .cfg_taps(e[5:0]), .cfg_coeffs(e[167:6]),
      .cfg_done(c_done), .cfg_error(c_err),
      .flush_valid(flush_req), .flush_ready(flush_rdy), .flush_done(flush_done),
      .input_count(), .output_count(), .capacity_error(cap_err));
  end
end else if (CORE == 3 || CORE == 4) begin: g_dd
  wire [370:0] e = (CORE == 3) ? dd_cfg(config_word[3:0]) : du_cfg(config_word[3:0]);
  reg seen_done, seen_err; wire c_done, c_err;
  always @(posedge clk50m) begin
    if (!core_reset) begin seen_done <= 0; seen_err <= 0; end
    else begin if (c_done) seen_done <= 1; if (c_err) seen_err <= 1; end
  end
  wire bad = (|config_word[31:4]) || (config_word[3:0] > 3);
  assign cfg_ready = seen_done | bad;
  assign cfg_error = seen_err | bad;
  wire signed [15:0] oi, oq;
  assign result = {oq[15:0], oi[15:0]};
  assign flush_rdy = 1'b0; assign flush_done = 1'b0;
  if (CORE == 3) begin: b_ddc
    ddc_stream #(.CIC_STAGES(3), .FIFO_REGS(1)) core(.clk(clk50m), .rst_n(core_reset),
      .s_i_tdata(input_q[15:0]), .s_q_tdata(input_q[31:16]),
      .s_tvalid(in_valid), .s_tready(in_ready),
      .m_i_tdata(oi), .m_q_tdata(oq), .m_clip(clip_w),
      .m_tvalid(out_valid), .m_tready(out_ready),
      .cfg_valid(state == CONFIG && !bad), .cfg_ready(),
      .cfg_phase_inc(e[31:0]), .cfg_phase_init(e[63:32]),
      .cfg_rate(e[70:64]), .cfg_shift(e[76:71]), .cfg_taps(e[82:77]),
      .cfg_coeffs(e[370:83]),
      .cfg_done(c_done), .cfg_error(c_err),
      .input_count(), .output_count(), .sat_count(), .fifo_overflow(cap_err));
  end else begin: b_duc
    duc_stream #(.CIC_STAGES(3)) core(.clk(clk50m), .rst_n(core_reset),
      .s_i_tdata(input_q[15:0]), .s_q_tdata(input_q[31:16]),
      .s_tvalid(in_valid), .s_tready(in_ready),
      .m_i_tdata(oi), .m_q_tdata(oq), .m_clip(clip_w),
      .m_tvalid(out_valid), .m_tready(out_ready),
      .cfg_valid(state == CONFIG && !bad), .cfg_ready(),
      .cfg_phase_inc(e[31:0]), .cfg_phase_init(e[63:32]),
      .cfg_rate(e[70:64]), .cfg_shift(e[76:71]), .cfg_taps(e[82:77]),
      .cfg_coeffs(e[370:83]),
      .cfg_done(c_done), .cfg_error(c_err),
      .input_count(), .output_count(), .sat_count());
    assign cap_err = 1'b0;
  end
end else if (CORE == 5) begin: g_median
  // isp/median/median_stream, 8 x 8 unsigned 8-bit, K=3.  The raster markers
  // are the same ones isp_stream_harness drives: start-of-frame on beat 0 and
  // end-of-line every 8 beats.  Only the low byte of each input word is a
  // pixel; the block is malformed unless it carries exactly IMAGE_PIXELS
  // beats, so the window engine always sees a whole frame.
  //
  // Both padding variants are built and wired to the same raster.  Their
  // control state machines are identical (only the padded value differs), so
  // s_tready never diverges and the muxed instance cannot deadlock; the unused
  // instance simply keeps computing the other padding for nothing.
  wire bad = (|config_word[31:1]);
  wire sel = config_word[0];
  wire [7:0] py0, py1;
  wire pv0, pu0, pl0, pr0, pe0;
  wire pv1, pu1, pl1, pr1, pe1;
  // The median of a fixed set of in-range pixels is in range, so an order
  // statistic cannot saturate: clip_w is tied low and flags[7] stays 0.
  assign clip_w = 1'b0;
  assign cap_err = 1'b0;
  assign flush_rdy = 1'b0;
  assign flush_done = 1'b0;
  // The core has no configuration handshake; the harness rejects an
  // out-of-range config_word itself, which keeps the flags[3] path exercised.
  assign cfg_ready = 1'b1;
  assign cfg_error = bad;
  assign in_ready = sel ? pr1 : pr0;
  assign out_valid = sel ? pv1 : pv0;
  // sof/eol/marker_error travel in the result word so the host checks them
  // against the model: bit8 = start of output frame, bit9 = end of output line,
  // bit10 = the core's sticky marker_error.  A lost or spurious marker is then
  // a numeric mismatch, not an invisible pass.
  assign result = {21'd0, sel ? pe1 : pe0, sel ? pl1 : pl0,
                   sel ? pu1 : pu0, sel ? py1 : py0};
  wire in_sof = (input_count == 0);
  wire in_eol = (input_count[2:0] == 3'd7);
  median_stream #(.BITS(8), .WIDTH(8), .HEIGHT(8), .K(3), .PAD_MODE(0),
                  .MAX_WIDTH(64)) med_zero(
    .clk(clk50m), .rst_n(core_reset),
    .s_tdata(input_q[7:0]), .s_tvalid(in_valid), .s_tuser(in_sof),
    .s_tlast(in_eol), .s_tready(pr0),
    .m_tdata(py0), .m_tvalid(pv0), .m_tuser(pu0), .m_tlast(pl0),
    .m_tready(out_ready), .marker_error(pe0));
  median_stream #(.BITS(8), .WIDTH(8), .HEIGHT(8), .K(3), .PAD_MODE(1),
                  .MAX_WIDTH(64)) med_rep(
    .clk(clk50m), .rst_n(core_reset),
    .s_tdata(input_q[7:0]), .s_tvalid(in_valid), .s_tuser(in_sof),
    .s_tlast(in_eol), .s_tready(pr1),
    .m_tdata(py1), .m_tvalid(pv1), .m_tuser(pu1), .m_tlast(pl1),
    .m_tready(out_ready), .marker_error(pe1));
end else if (CORE == 6) begin: g_pfb
  // dsp/pfb/rtl/pfb_stream, M=8 channels x P=8 taps.  M and P are elaboration
  // parameters of the core, so this image verifies ONE channelizer geometry;
  // a block of in_count samples yields exactly in_count channel beats
  // (critically sampled), which is the shape BLK2 already carries -- the
  // tracker's "needs multi-channel adapter" note was stale.
  //
  // Not covered by this branch, and not claimed: the per-channel gain port is
  // held inactive, so the core keeps its reset gains (1.0 in Q2.16) and the
  // atomic-commit / cfg_addr>=M error paths are untested here.  With passband
  // gain ~0.13 a signed16 input block cannot saturate the FIR or the gain
  // stage, so flags[7] stays low exactly as the model predicts.
  // CORE 6 has no configuration choice at all: M and P are elaboration
  // parameters, so config_word 0 is the only legal value and EVERY nonzero
  // bit must be refused.  Testing only bits [31:1] let config_word 1 through
  // to be silently ignored, which reported a count mismatch for a request the
  // transport should have rejected as an unknown config.
  wire bad = |config_word;
  assign cfg_ready = 1'b1;
  assign cfg_error = bad;
  assign cap_err = 1'b0;
  assign flush_rdy = 1'b0;
  assign flush_done = 1'b0;
  pfb_stream #(.M(8), .P(8)) core(
    .clk(clk50m), .rst_n(core_reset),
    .s_tdata(input_q), .s_tvalid(in_valid), .s_tready(in_ready),
    .m_tdata(result), .m_tid(), .m_tuser(), .m_tlast(),
    .m_tvalid(out_valid), .m_tready(out_ready),
    .cfg_valid(1'b0), .cfg_ready(), .cfg_addr(5'd0), .cfg_gain(18'sd65536),
    .cfg_done(), .cfg_error(),
    .busy(), .cnt_in(), .cnt_frames(), .cnt_out(),
    .clip_sticky(clip_w));
end else if (CORE == 7) begin: g_framediff
  // isp/framediff/rtl/framediff_stream, BITS=8 at 4x4 (MAX_W/MAX_H = 4, so the
  // reference RAM is 16 entries and CWX=CWY=3).  A plain block pulses the core
  // reset first, so it has to carry the whole sequence it wants differenced --
  // up to FOUR frames, and the frame written by frame N is what frame N+1
  // differences against.  A rsvd=1 PERSIST block leaves that RAM standing, so
  // the same sequence can also arrive as four one-frame blocks, and a rsvd=3
  // block changes mode/threshold/alpha/scene-policy mid-session.  Only a
  // geometry change (different W/H, which clears validity) stays unverified:
  // the harness drives one fixed raster and a table-free config word.
  wire bad = |config_word[31:4];
  wire [22:0] e = fd_cfg(config_word[3:0]);
  reg seen_done, seen_err; wire c_done, c_err;
  always @(posedge clk50m) begin
    if (!core_reset) begin seen_done <= 1'b0; seen_err <= 1'b0; end
    if (c_done) seen_done <= 1'b1;
    if (c_err)  seen_err <= 1'b1;
  end
  assign cfg_ready = seen_done | bad;
  assign cfg_error = seen_err | bad;
  // Neither output can saturate: DIFF/MOTION emit 0 or the all-ones mask, and
  // the running mean stays inside [min(ref,cur), max(ref,cur)] for in-range
  // pixels, so flags[7] has nothing to report and stays low as the model says.
  assign clip_w = 1'b0;
  assign cap_err = 1'b0;
  assign flush_rdy = 1'b0;
  assign flush_done = 1'b0;
  wire [7:0] fd_y;
  wire fd_u, fd_l, fd_scn_p, fd_oerr_p, pv, pr;
  assign in_ready = pr;
  assign out_valid = pv;
  // o_error is a pulse on the accept cycle that violated a marker rule, two
  // cycles before the matching result word leaves; a sticky bit is enough to
  // prove the harness drove a legal raster, and the model predicts zero.
  reg fd_merr = 1'b0, fd_scn_hold = 1'b0;
  always @(posedge clk50m) begin
    // Cleared at every block boundary, not only on a core reset: the raster the
    // harness drives is per block, so a session's later blocks must not inherit
    // an earlier block's marker error (the reference frame in ref_ram is the
    // only thing persistence is for).
    if (!core_reset || state == RESET) begin
      fd_merr <= 1'b0; fd_scn_hold <= 1'b0;
    end else begin
      if (fd_oerr_p) fd_merr <= 1'b1;
      // scn_event rises with the frame's last output pixel already on the bus,
      // so it belongs to the word firing this cycle; when the reply path is
      // stalled it has to wait for that word instead of being lost.
      if (fd_scn_p && !output_fire) fd_scn_hold <= 1'b1;
      if (output_fire) fd_scn_hold <= 1'b0;
    end
  end
  assign result = {20'd0, (fd_scn_hold | fd_scn_p), fd_merr, fd_l, fd_u, fd_y};
  wire in_sof = (input_count[3:0] == 4'd0);
  wire in_eol = (input_count[1:0] == 2'd3);
  framediff_stream #(.BITS(8), .MAX_W(FD_GW), .MAX_H(FD_GH)) core(
    .clk(clk50m), .rst_n(core_reset),
    .s_tdata(input_q[7:0]), .s_tvalid(in_valid), .s_tuser(in_sof),
    .s_tlast(in_eol), .s_tready(pr),
    .m_tdata(fd_y), .m_tvalid(pv), .m_tuser(fd_u), .m_tlast(fd_l),
    .m_tready(out_ready),
    .cfg_valid(state == CONFIG && !bad), .cfg_ready(),
    .cfg_width(3'd4), .cfg_height(3'd4),
    .cfg_mode(e[1:0]), .cfg_thresh(e[9:2]), .cfg_alpha(e[13:10]),
    .cfg_scn(e[21:14]), .cfg_scpol(e[22]),
    .cfg_done(c_done), .cfg_error(c_err),
    .o_error(fd_oerr_p), .scn_event(fd_scn_p), .busy());
end else if (CORE == 8) begin: g_ccm
  // isp/ccm/rtl/ccm_stream.sv, BITS=8: Q2.13 3x3 color matrix + 33-node PWL
  // tone per channel.  config_word[3:0] picks one of eight bundles and the
  // loader writes the WHOLE shadow image -- ctrl + 9 matrix + 3 bias + 99 lin +
  // 99 enc nodes = 211 beats -- then pulses cfg_commit, because ccm_stream
  // validates the complete shadow at commit rather than each write: a bundle
  // that only half landed would either be rejected (which the host must see as
  // flags[3]) or silently apply a matrix the oracle never ran.
  //
  // CONFIG cannot wait for cfg_done the way the other cores do.  A legal commit
  // applies only at a presented SOF with an empty pipe, which for this harness
  // is the block's FIRST RUN beat -- strictly after CONFIG ends, so cfg_done
  // would never arrive in CONFIG.  Instead the loader leaves on a bounded scan
  // window: the core's legality check walks 99 flat node indices, one per cycle,
  // so by cycle 110 after the commit edge the verdict is in either form (a
  // header violation pulses cfg_error on the commit edge itself, a monotone
  // violation at the end of the scan).  Requiring cfg_pending to still be high
  // at that point is the positive half of the same check: pending_apply is what
  // a legal commit sets, so a core that neither errored nor armed a pending
  // apply holds CONFIG until the watchdog and reports a rejected bundle rather
  // than passing a block it never configured.
  // Bundle 7 is the last entry ccm_cfg() knows, so an index above it must be
  // refused rather than silently loading the default -- ccm_cfg()'s own default
  // arm is only a latch-up guard, not a configuration the host may ask for.
  wire bad = (|config_word[31:4]) || (config_word[3:0] > 4'd7);
  wire [15:0] e = ccm_cfg(config_word[3:0]);
  reg seen_err; wire c_err;
  // Cleared at every block boundary, not only on a core reset: a session's
  // RECONFIG block must be judged on its own bundle.
  always @(posedge clk50m)
    if (!core_reset || state == RESET) seen_err <= 1'b0;
    else if (c_err)                     seen_err <= 1'b1;
  // Loader stages: 0 ctrl, 1 matrix, 2 bias, 3 lin nodes, 4 enc nodes,
  // 5 commit, 6 scan window.
  reg [2:0]  ldr;
  reg [3:0]  midx;
  reg [1:0]  bidx;
  reg [5:0]  ni;                 // node index 0..32 inside a channel
  reg [1:0]  nc;                 // node channel 0..2 (c0=B, c1=G, c2=R)
  reg [7:0]  nbase;              // nc*33, kept as a running sum: no divider
  reg [7:0]  sset;
  reg [11:0] cw;                 // CONFIG-window watchdog
  wire c_ready, ccm_pend;
  wire writing  = (state == CONFIG) && !bad && ldr <= 3'd4;
  wire ccm_com  = (state == CONFIG) && !bad && ldr == 3'd5;
  wire [1:0] node_code = (nc == 2'd0) ? e[10:9]
                           : (nc == 2'd1) ? e[8:7] : e[6:5];
  // The committed `domain` bit picks which bank becomes the active table, so the
  // curve set is written into that bank and the other bank keeps the core's
  // identity reset default -- exactly what _ccm_cfg() hands the oracle.
  wire use_curve = (ldr == 3'd3) ? !e[1] : e[1];
  wire [7:0] node_v = use_curve ? ccm_node(node_code, ni) : ccm_node(2'd0, ni);
  wire [7:0] ccm_waddr =
      (ldr == 3'd0) ? 8'h00 :
      (ldr == 3'd1) ? 8'h01 + {4'd0, midx} :
      (ldr == 3'd2) ? 8'h0A + {6'd0, bidx} :
      (ldr == 3'd3) ? 8'h10 + nbase + {2'd0, ni} :
                      8'h80 + nbase + {2'd0, ni};
  wire [15:0] ccm_wdata =
      (ldr == 3'd0) ? {12'd0, e[1], e[3], e[2], e[4]} :
      (ldr == 3'd1) ? ccm_matrix(e[14:12], midx) :
      (ldr == 3'd2) ? ccm_bias(e[11], bidx) :
                      {8'd0, node_v};
  wire scan_done = (ldr == 3'd6) &&
                   (seen_err || (sset >= 8'd110 && ccm_pend));
  wire watchdog  = (cw >= 12'd4095);
  assign cfg_ready = bad | scan_done | watchdog;
  assign cfg_error = bad | seen_err | watchdog;
  // ccm_stream has NO saturation output: quantize() clamps to [0,MPX] inside the
  // datapath and reports nothing, so flags[7] can only ever stay low here.  That
  // is why every ccm case in protocol.py is asserted clamp-free against the
  // pre-clamp quantization -- a case that saturated would otherwise be an
  // unverified agreement between a clamping DUT and a low flag.
  assign clip_w = 1'b0;
  assign cap_err = 1'b0;
  assign flush_rdy = 1'b0;
  assign flush_done = 1'b0;
  wire [23:0] ccm_y;
  wire ccm_u, ccm_l, pv, pr;
  assign in_ready = pr;
  assign out_valid = pv;
  // SOF/EOL ride the reply word at bits 24/25 as they do for CORE 7: the core
  // transports markers rather than decoding them, so this proves the raster the
  // host assumed is the raster the pipeline saw.
  assign result = {6'd0, ccm_l, ccm_u, ccm_y};
  wire in_sof = (input_count == 7'd0);
  wire in_eol = (input_count[1:0] == 2'd3);
  always @(posedge clk50m) begin
    if (!core_reset || state == RESET) begin
      ldr <= 3'd0; midx <= 4'd0; bidx <= 2'd0; ni <= 6'd0;
      nc <= 2'd0; nbase <= 8'd0; sset <= 8'd0; cw <= 12'd0;
    end else if (state == CONFIG && !bad) begin
      cw <= cw + 12'd1;
      case (ldr)
        3'd0:    if (c_ready) ldr <= 3'd1;
        3'd1: if (c_ready) begin
                 if (midx == 4'd8) ldr  <= 3'd2;
                 else              midx <= midx + 4'd1;
               end
        3'd2: if (c_ready) begin
                 if (bidx == 2'd2) ldr  <= 3'd3;
                 else              bidx <= bidx + 2'd1;
               end
        3'd3, 3'd4: if (c_ready) begin
                 if (ni == 6'd32) begin
                   ni <= 6'd0;
                   if (nc == 2'd2) begin
                     nc <= 2'd0; nbase <= 8'd0; ldr <= ldr + 3'd1;
                   end else begin
                     nc <= nc + 2'd1; nbase <= nbase + 8'd33;
                   end
                 end else ni <= ni + 6'd1;
               end
        3'd5:    ldr <= 3'd6;
        default: sset <= sset + 8'd1;
      endcase
    end
  end
  ccm_stream #(.BITS(8)) core(.clk(clk50m), .rst_n(core_reset),
    .s_tdata(input_q[23:0]), .s_tvalid(in_valid), .s_tuser(in_sof),
    .s_tlast(in_eol), .s_tready(pr),
    .m_tdata(ccm_y), .m_tvalid(pv), .m_tuser(ccm_u), .m_tlast(ccm_l),
    .m_tready(out_ready),
    .cfg_valid(writing), .cfg_ready(c_ready),
    .cfg_addr(ccm_waddr), .cfg_wdata(ccm_wdata),
    .cfg_commit(ccm_com), .cfg_done(), .cfg_error(c_err),
    .cfg_pending(ccm_pend), .stat_domain(), .busy());
end else begin: bad_core
  assign in_ready = 1'b0; assign out_valid = 1'b0; assign cfg_ready = 1'b1;
  assign cfg_error = 1'b1; assign clip_w = 1'b0; assign cap_err = 1'b0;
  assign flush_rdy = 1'b0; assign flush_done = 1'b0; assign result = 32'b0;
end
endgenerate

// --------------------------------------------------------------- stores ----
// Input store: 64 x 32, written as the block payload streams in.
wire input_read = state == PREFETCH || in_valid;
wire [5:0] input_address = state == PREFETCH ? 6'd0 :
    (input_fire ? input_count[5:0] + 6'd1 : input_count[5:0]);

wire input_write = rst_n && state == LOAD && rx_valid && index >= 16
                && byte_index[1:0] == 3 && byte_index < data_bytes[8:0];

// How many 32-bit input words this block actually stored.  The block is run on
// the header's declared count, so a word that never arrived leaves the core
// reading whatever the store holds at that address - in simulation 'x' (and the
// payload CRC cannot see it, because the loss is internal to the harness), on
// silicon some real level, which is the one mechanism that would put a single
// absurd value through the accumulator and make the output exactly the saturation
// constant with the clip bit set while every other word stays byte-exact.
// flags[1] (rx_framing_error, previously never assigned) reports it per block.
reg store_begin = 1'b0;   // one pulse when a BLK2 request begins
reg wrote_all = 1'b0;     // registered: the declared word count has landed
reg [8:0] words_written = 9'd0;
always @(posedge clk50m)
  if (store_begin) begin
      words_written <= 9'd0; wrote_all <= 1'b0;
  end else if (input_write) begin
      words_written <= words_written + 9'd1;
      // registered verdict: TRAIL reads a flop instead of settling a
      // 9-bit comparator in the same cycle it decides to run the core
      wrote_all     <= (words_written + 9'd1) == {1'b0, count};
  end
block_ram #(.MEM_IMPL(0)) input_store(.clk(clk50m), .we(input_write),
    .waddr(byte_index[7:2]), .wdata({rx_data, assembly[23:0]}),
    .re(input_read), .raddr(input_address), .q(input_q));

// Output store: 128 words as two 64x32 banks, MSB-selected.
wire owe = output_fire && !output_count[7];
wire [31:0] oq_lo, oq_hi;
// The read is issued in the RDW cycle only: the store has a registered output,
// so its q is exactly the word being emitted during the four DATA cycles that
// follow.  Asserting re in DATA as well would make every word's byte lane 0
// read the PREVIOUS address, which is visible as a wrong (or, across the bank
// switch, undefined) byte on the wire.
wire ore = state == RDW;
block_ram #(.MEM_IMPL(0)) output_lo(.clk(clk50m), .we(owe && !output_count[6]),
    .waddr(output_count[5:0]), .wdata(result), .re(ore),
    .raddr(read_index[5:0]), .q(oq_lo));
block_ram #(.MEM_IMPL(0)) output_hi(.clk(clk50m), .we(owe && output_count[6]),
    .waddr(output_count[5:0]), .wdata(result), .re(ore),
    .raddr(read_index[5:0]), .q(oq_hi));
assign output_q = read_index[6] ? oq_hi : oq_lo;

// ------------------------------------------------------------ responses ----
// Byte 0..19 of RES2 (header) / 0..3 of STAT (magic) / STAT counter bytes.
reg [7:0] hdr_byte;
always @* begin
    hdr_byte = 8'd0;
    case (wi[4:0])
        5'd0:  hdr_byte = mode_blk ? "R" : (reply_dbg ? "D" : "S");
        5'd1:  hdr_byte = mode_blk ? "E" : (reply_dbg ? "B" : "T");
        5'd2:  hdr_byte = mode_blk ? "S" : (reply_dbg ? "G" : "A");
        5'd3:  hdr_byte = mode_blk ? "2" : (reply_dbg ? "2" : "T");
        5'd4:  hdr_byte = tag[7:0];
        5'd5:  hdr_byte = tag[15:8];
        5'd6:  hdr_byte = tag[23:16];
        5'd7:  hdr_byte = tag[31:24];
        5'd8:  hdr_byte = config_word[7:0];
        5'd9:  hdr_byte = config_word[15:8];
        5'd10: hdr_byte = config_word[23:16];
        5'd11: hdr_byte = config_word[31:24];
        5'd12: hdr_byte = count;
        5'd13: hdr_byte = flags;
        5'd14: hdr_byte = {1'b0, input_count};
        5'd15: hdr_byte = output_count;
        5'd16: hdr_byte = cycles_report[7:0];
        5'd17: hdr_byte = cycles_report[15:8];
        5'd18: hdr_byte = cycles_report[23:16];
        5'd19: hdr_byte = cycles_report[31:24];
        default: hdr_byte = 8'd0;
    endcase
end

wire [31:0] sta_word = sr_chain[319:288];

wire [15:0] sta_off = wi - 16'd4;
wire [7:0] sta_byte = sta_word[({2'b0, sta_off[1:0]} * 16'd8) +: 8];

// A result word is real only while its index is below outc; the rest is zero
// padding, which the host discards using the declared outc anyway.
wire word_valid = ({1'b0, rdw} < output_count) || output_count == 8'd128;
wire [7:0] data_byte = word_valid ? output_q >> (8 * lane) : 8'd0;

reg [7:0] wr_byte;
always @* begin
    case (state)
        HDRO:  wr_byte = hdr_byte;
        DATA:  wr_byte = data_byte;
        SBYTE: wr_byte = sta_byte;
        default: wr_byte = 8'd0;
    endcase
end

// Write strobes are range-gated: HDRO emits the 20 RES2 header bytes (or the
// 4 STAT magic bytes) and nothing beyond, so a stale 0 can never land in the
// result-word area of the TX RAM.
assign tx_wr = (state == HDRO && ((mode_blk && wi < 20) || (!mode_blk && wi < 4)))
            || (state == DATA)
            || (state == SBYTE && wi >= 4 && wi < STA_LEN);
assign tx_wr_addr = wi;
assign tx_wr_data = wr_byte;

wire run_done = (HAS_FLUSH ? (drained && !out_valid && !output_fire)
                           : (inputs_done && quiet == QUIET_MAX && !out_valid))
                || (output_count[7] && out_valid);

// --------------------------------------------------------------- control ---
always @(posedge clk50m) begin
    if (!rst_n) begin
        state <= LOAD; index <= 0; byte_index <= 0; count <= 0; stall <= 0;
        flags <= 0; out_expect <= 0; rsvd_b <= 0; tag <= 0; config_word <= 0;
        pers_b <= 0; rcfg_b <= 0; configured <= 0;
        assembly <= 0; cycles <= 0; input_count <= 0; output_count <= 0;
        last_act <= 0; saw_act <= 0;
        read_index <= 0; phase <= 0; quiet <= 0; flush_sent <= 0; drained <= 0;
        wi <= 0; rdw <= 0; lane <= 0; mode_blk <= 1'b1; reply_dbg <= 1'b0;
        reply_len <= 0;
        cyc_total <= 0; words_in <= 0; words_out <= 0; blocks_done <= 0;
        tx_req_p <= 1'b0; txgo_count <= 0; done_q <= 1'b0; dg_done <= 1'b0;
    end else begin
        // A late-octet is only meaningful before this datagram was answered or
        // verified; octets that stream while the reply leaves (trailer, pad)
        // belong to an already-handled datagram and do not count.
        if (rx_start) dg_done <= 1'b0;
        store_begin <= 1'b0;
        if (rx_valid && state != LOAD && !dg_done) flags[2] <= 1;
        // Every reply goes back to the peer that asked for it.  The latch only
        // moves on a datagram boundary, so it is stable across the pipe's
        // two-cycle request arbitration.
        if (rx_start) begin
            tx_dst_ip_r   <= rx_src_ip;
            tx_dst_port_r <= rx_src_port;
        end
        // A fresh datagram always restarts block parsing, so a truncated or
        // unexpected frame can never wedge the receive path.
        if (rx_start && state == LOAD && index != 0) begin
            index <= 0; byte_index <= 0;
        end

        case (state)
        // ----------------------------------------------------- receive -----
        LOAD: if (rx_valid) begin
            case (index)
            0: if (rx_data == "D") begin
                   index <= 50;
               end else if (rx_data == "B") begin
                   store_begin <= 1'b1;
                   index <= 1; flags <= 0; input_count <= 0;
                   output_count <= 0; cycles <= 0; mode_blk <= 1'b1;
                   reply_dbg <= 1'b0;
                   last_act <= 0; saw_act <= 0;
               end else if (rx_data == "S") begin
                   index <= 40; mode_blk <= 1'b0;
               end else index <= 0;
            1: if (rx_data == "L") index <= 2; else index <= 0;
            2: if (rx_data == "K") index <= 3; else index <= 0;
            3: if (rx_data == "2") index <= 4; else index <= 0;
            4,5,6,7:       begin tag         <= {rx_data, tag[31:8]};         index <= index + 1'b1; end
            8,9,10,11:     begin config_word <= {rx_data, config_word[31:8]}; index <= index + 1'b1; end
            12: begin count <= rx_data; index <= 13; end
            13: begin stall <= rx_data; index <= 14; end
            14: begin out_expect <= rx_data; index <= 15; end
            15: begin rsvd_b <= rx_data; pers_b <= rx_data[0];
                  rcfg_b <= rx_data[1]; index <= 16; byte_index <= 0;
                  if (count == 0 || count > ETH_IN_CAP || stall > 7 ||
                      out_expect > OUT_CAP || rx_data > 8'd3 ||
                      rx_data == 8'd2 ||   // RECONFIG without PERSIST: no such
                      (CORE == 5 && count != IMAGE_PIXELS) ||
                      (CORE == 7 && (count[3:0] != 4'd0 ||
                                     count > FD_PIXELS))) begin
                      flags[0] <= 1; count <= 0; output_count <= 0;
                      wi <= 0; state <= HDRO; dg_done <= 1; reply_len <= RES_LEN;
                  end
              end
            // STA1 tail: snapshot the counters and emit STAT.
            40: if (rx_data == "T") index <= 41; else begin index <= 0; mode_blk <= 1'b1; end
            41: if (rx_data == "A") index <= 42; else begin index <= 0; mode_blk <= 1'b1; end
            42: if (rx_data == "1") begin
                    sr_chain <= {stat_rx_frames, stat_rx_udp, stat_ping,
                                 stat_tx_frames, stat_rx_err, cyc_total,
                                 words_in, words_out, blocks_done,
                                 {24'd0, CORE_ID_B}};
                    // HDRO writes the "STAT" magic, then SBYTE the counters.
                    wi <= 0; mode_blk <= 1'b0; reply_dbg <= 1'b0;
                    reply_len <= STA_LEN; dg_done <= 1;
                    state <= HDRO;
                end else begin index <= 0; mode_blk <= 1'b1; end
            // DBG1 tail: emit the last rejected frame's parser snapshot.
            50: if (rx_data == "B") index <= 51; else begin index <= 0; mode_blk <= 1'b1; end
            51: if (rx_data == "G") index <= 52; else begin index <= 0; mode_blk <= 1'b1; end
            52: if (rx_data == "1") begin
                    sr_chain <= {dbg_frame[215:184], dbg_frame[183:152],
                                 dbg_frame[151:120], dbg_frame[119:88],
                                 dbg_frame[87:56], dbg_frame[55:24],
                                 {8'd0, dbg_frame[23:0]}, 32'd0, 32'd0,
                                 {24'd0, CORE_ID_B}};
                    wi <= 0; mode_blk <= 1'b0; reply_dbg <= 1'b1;
                    reply_len <= STA_LEN; dg_done <= 1;
                    state <= HDRO;
                end else begin index <= 0; mode_blk <= 1'b1; end
            // Block payload words plus the 4-octet CRC-32 trailer the host
            // appends (this PHY clips the wire FCS, so integrity rides inside
            // the payload).  Trailer octets never reach input RAM.
            default: begin
                byte_index <= byte_index + 1'b1;
                if (byte_index[1:0] == 0) assembly[7:0]   <= rx_data;
                if (byte_index[1:0] == 1) assembly[15:8]  <= rx_data;
                if (byte_index[1:0] == 2) assembly[23:16] <= rx_data;
                if (byte_index == data_bytes[8:0] + 9'd3) begin
                    state <= TRAIL; dg_done <= 1;
                end
            end
            endcase
        end

        // One beat after the datagram's last octet: the pipe has posted the
        // payload-CRC verdict.  A corrupt request is dropped without a reply
        // (the host times out and retries); only verified input runs a core.
        TRAIL: if (pay_ok) begin
                   if (!wrote_all) flags[1] <= 1'b1;
                   state <= RESET;
               end
               else begin state <= LOAD; index <= 0; byte_index <= 0; end

        RESET: begin
            input_count <= 0; output_count <= 0; cycles <= 0; phase <= 0;
            last_act <= 0; saw_act <= 0;
            quiet <= 0; flush_sent <= 0; drained <= 0;
            state <= cfg_skip ? CHECK : CONFIG;
        end
        CONFIG: if (cfg_ready) begin
            // Only a legal commit arms a session: an image that rejected the
            // bundle has no valid configuration to persist into the next block.
            if (!cfg_error) configured <= 1'b1;
            state <= CHECK;
        end
        CHECK: if (cfg_error) begin
            flags[3] <= 1; count <= 0; output_count <= 0;
            wi <= 0; reply_len <= RES_LEN; state <= HDRO;
        end else state <= PREFETCH;
        PREFETCH: state <= RUN;
        RUN: begin
            cycles <= cycles + 1'b1;
            phase <= phase + 1'b1;
            if (input_fire) begin
                input_count <= input_count + 1'b1;
                words_in <= words_in + 1'b1;
            end
            if (input_fire || output_fire) begin
                last_act <= cycles;
                saw_act <= 1'b1;
            end
            if (!inputs_done || out_valid || output_fire || input_fire) quiet <= 0;
            else quiet <= quiet + 1'b1;
            if (flush_req && flush_rdy) flush_sent <= 1;
            if (flush_done) drained <= 1;
            if (output_fire) begin
                words_out <= words_out + 1'b1;
                if (!output_count[7]) output_count <= output_count + 1'b1;
                else flags[6] <= 1;
            end
            if (output_fire && clip_w) flags[7] <= 1;
            if (cap_err) flags[6] <= 1;
            if (run_done || cycles == 32'd65535) begin
                // The dock PHY clips the last ~2 octets of the carrier, so the
                // Ethernet FCS can never verify on RX (dbg_frame evidence) --
                // fcs_ok stays observational.  Integrity is instead enforced
                // end-to-end: the host compares every result word to the model
                // and retries on mismatch, while bad-FCS replies get dropped
                // by the host NIC and also retry.
                // The RUN branch above also increments cycles this cycle,
                // and the reply header is built after that increment, so a
                // block reports elapsed+1.  Add the same +1 here or the
                // summary counter would fall one cycle behind the
                // per-block reports for every block.  The tail-stripped
                // report reads last_act, which is already final (a block
                // only ends 4095 cycles after its last handshake), so it
                // needs no correction.
                cyc_total <= cyc_total + cycles_report
                                          + (tail_stripped ? 32'd0 : 32'd1);
                blocks_done <= blocks_done + 1'b1;
                if (cycles == 32'd65535) flags[4] <= 1;
                if (output_count + (output_fire && !output_count[7] ? 8'd1 : 8'd0)
                        != out_expect) flags[5] <= 1;
                wi <= 0; reply_len <= RES_LEN; state <= HDRO;
            end
        end

        // ------------------------------------------------------- send ------
        // Header or magic bytes, one per cycle.
        HDRO: begin
            read_index <= 0;
            if (mode_blk) begin
                if (wi < 20) wi <= wi + 1'b1;
                if (wi == 19) begin
                    rdw <= 0; lane <= 0; read_index <= 0;
                    state <= RDW;
                end
            end else begin
                if (wi < 4) wi <= wi + 1'b1;
                else state <= SBYTE;
            end
        end
        // RDW issues the registered store read for word rdw; q is valid for the
        // four DATA cycles that follow.
        RDW: state <= DATA;
        DATA: begin
            wi <= wi + 1'b1;
            lane <= lane + 1'b1;
            if (lane == 2'd3) begin
                if (rdw == OUT_CAP - 1) begin
                    wi <= 0; state <= TXGO;
                end else begin
                    rdw <= rdw + 1'b1;
                    read_index <= read_index + 1'b1;
                    state <= RDW;
                end
            end
        end
        SBYTE: begin
            if (wi >= 4 && wi < STA_LEN) begin
                wi <= wi + 1'b1;
                // last byte of this word is on the wire: bring up the next one
                if (sta_off[1:0] == 2'd3 && wi + 16'd1 < STA_LEN)
                    sr_chain <= {sr_chain[287:0], 32'd0};
            end
            else begin wi <= 0; state <= TXGO; end
        end
        // Issue tx_req once, then wait for the pipe to drain.  A done pulse
        // that still leaves tx_busy high belongs to an ARP or ICMP reply that
        // won arbitration, not to our datagram, so it must not end the wait.
        TXGO: begin
            txgo_count <= txgo_count + 1'b1;
            tx_req_p <= (txgo_count == 32'd1);
            done_q <= tx_done;
            if (((txgo_count > 32'd8) && done_q && !tx_busy)
                    || txgo_count == TXGO_MAX) begin
                state <= LOAD; index <= 0; byte_index <= 0;
                count <= 0; txgo_count <= 0;
            end
        end
        default: state <= LOAD;
        endcase
    end
end

assign led[0] = phy_ready;
assign led[1] = rx_valid;
assign led[2] = (state == RUN);
assign led[3] = tx_busy;
assign led[4] = |flags;
assign led[5] = cyc_total[23];

endmodule
