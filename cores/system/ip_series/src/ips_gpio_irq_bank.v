`timescale 1ns / 1ps
// ips_gpio_irq_bank : 32-bit GPIO bank with direction, polarity, edge/level
// interrupt, sticky status and clear-on-write.
//
// Written contract.  Both src/ips_gpio_irq_bank.v and models/ips_gpio_irq_bank.py
// are derived from this text; neither is back-filled from simulation output
// (docs/IP_CORE_SOP.md trap T1).  Every register is gated by clk_en and rst_n is
// the active-low asynchronous reset.
//
//   The interrupt logic services the low 16 lines of the 32-bit pad word; the
//   host register words are 32 bit wide and read back as {16'h0000, bank}.
//
//   Sample calendar.  sync_idx steps once per enabled beat and wraps to zero on
//   the beat where it equals SYNC_WRAP.  The two-flop synchroniser only moves on
//   a wrap beat: sync_meta <= pin_in[15:0], sync_q <= sync_meta.  sync_d copies
//   sync_q on every enabled beat, so sync_q and sync_d are the last two samples.
//
//   Interrupt latch, evaluated on every enabled beat from the pre-edge state:
//     rise = sync_q & ~sync_d, fall = ~sync_q & sync_d
//     edge_arm = (pol_r & rise) | (~pol_r & fall)
//     lev_arm  = (pol_r & sync_q) | (~pol_r & ~sync_q)
//     newly = (mode_g ? edge_arm : lev_arm) & ie_next & ~pend
//   mode_g (address 2, bit 0) selects edge (1) or level (0) sensing and pol_r is
//   the per-line polarity (1 = rising edge / active-high level).  newly uses the
//   enable image including an enable write issued in the same beat, and a line
//   that is already pending cannot re-arm because of the ~pend mask.
//
//   pend order per enabled beat: arm newly, then write-1-to-clear of a write to
//   address 3, then a full clear when bus_ack is high.  bus_ack is sticky-latched
//   into `acked`.  level_any is the combinational pending-on-disabled-line flag
//   |(pend & ~ie_r & (sync_q ^ sync_d)).
//
//   Counters.  set_evts counts enabled beats that armed at least one line and
//   saturates at EVT_SAT; storm is the sticky flag set by the beat that reaches
//   EVT_SAT.  w1c_evts counts write-1-to-clear beats with a non-zero mask and
//   err_count counts invalid-address accesses; both saturate at CNT_SAT.
//
//   irq_vec is the lowest armed line of (pend_next & ie_next) biased by VEC_BIAS,
//   with irq_active marking the request.
//
//   Register map (bank half = bus_wdata[15:0]):
//     0 DIR     write dir_r, read {16'h0000, dir_r}
//     1 POL     write pol_r, read {16'h0000, pol_r}
//     2 MODEIE  write mode_g = bit0 and ie_r = {4{bit[7:4]}},
//               read {16'h0000, 11'h0, mode_g, ie_r[3:0]}
//     3 PEND    write-1-to-clear, read {16'h0000, pend}
//     4 OUT     write out_r, read {16'h0000, out_r}
//     5 STAT    read-only {13'h0, err_count, w1c_evts, set_evts, irq_active,
//               storm, acked, level_any, sync_idx}; writes are ignored
//     6..15     ILLEGAL: a write steps err_count and every read returns
//               INVALID_RD.  No silent aliasing onto a live register.
//
//   bus_rdata is registered, so a read returns the mux value of the beat in
//   progress, i.e. the bank as of one beat before the write that shares it.
//
//   pin_out = {16'h0000, out_r & dir_r}, combinational output-enable mask.
//
// No state can hang: sync_idx is a 2-bit calendar (all four encodings legal) and
// the read/write decode carries an explicit illegal-address arm.
module ips_gpio_irq_bank (
    input  wire         clk,
    input  wire         clk_en,
    input  wire         rst_n,

    input  wire [31:0]  pin_in,
    input  wire [3:0]   bus_addr,
    input  wire         bus_we,
    input  wire [31:0]  bus_wdata,
    input  wire         bus_ack,

    output reg  [31:0]  bus_rdata,
    output reg  [15:0]  pend,
    output wire [31:0]  pin_out,
    output reg          irq_active,
    output reg  [3:0]   irq_vec,
    output reg          storm,
    output reg          acked,
    output reg  [1:0]   sync_idx,
    output reg  [4:0]   set_evts,
    output reg  [3:0]   w1c_evts,
    output reg  [3:0]   err_count,
    output wire         level_any
);

localparam [1:0]  SYNC_WRAP  = 2'd2;
localparam [4:0]  EVT_SAT    = 5'd28;
localparam [31:0] INVALID_RD = 32'hDEADB100;
localparam [3:0]  VEC_BIAS   = 4'h5;
localparam [3:0]  CNT_SAT    = 4'h9;
localparam [3:0]  A_DIR = 4'h0, A_POL = 4'h1, A_MIE = 4'h2, A_PEND = 4'h3,
                  A_OUT = 4'h4, A_STAT = 4'h5;

reg [15:0] dir_r, pol_r, ie_r, out_r;
reg [15:0] sync_meta, sync_q, sync_d;
reg        mode_g;

wire        sync_step = (sync_idx == SYNC_WRAP);
wire [15:0] wlo       = bus_wdata[15:0];
wire        is_dir    = (bus_addr == A_DIR);
wire        is_pol    = (bus_addr == A_POL);
wire        is_mie    = (bus_addr == A_MIE);
wire        is_pend   = (bus_addr == A_PEND);
wire        is_out    = (bus_addr == A_OUT);
wire        is_stat   = (bus_addr == A_STAT);
wire        bad_addr  = (bus_addr != A_DIR) && (bus_addr != A_POL) &&
                        (bus_addr != A_MIE) && (bus_addr != A_PEND) &&
                        (bus_addr != A_OUT) && (bus_addr != A_STAT);
wire        w_dir     = bus_we & is_dir;
wire        w_pol     = bus_we & is_pol;
wire        w_mie     = bus_we & is_mie;
wire        w_pend    = bus_we & is_pend;
wire        w_out     = bus_we & is_out;

wire [15:0] ie_next   = w_mie ? {4{bus_wdata[7:4]}} : ie_r;
wire        mode_next = w_mie ? bus_wdata[0] : mode_g;

wire [15:0] rise    =  sync_q & ~sync_d;
wire [15:0] fall    = ~sync_q & sync_d;
wire [15:0] changed =  sync_q ^  sync_d;
wire [15:0] edge_arm = (pol_r & rise) | (~pol_r & fall);
wire [15:0] lev_arm  = (pol_r & sync_q) | (~pol_r & ~sync_q);
wire [15:0] newly    = (mode_g ? edge_arm : lev_arm) & ie_next & ~pend;
wire [15:0] w1c      = w_pend ? wlo : 16'h0000;
wire [15:0] pend_nx  = bus_ack ? 16'h0000 : ((pend | newly) & ~w1c);
wire [15:0] arm      = pend_nx & ie_next;
wire [3:0]  v0 = arm[0]    ? 4'd0  : arm[1]    ? 4'd1  : arm[2]    ? 4'd2  : 4'd3;
wire [3:0]  v1 = arm[4]    ? 4'd4  : arm[5]    ? 4'd5  : arm[6]    ? 4'd6  : 4'd7;
wire [3:0]  v2 = arm[8]    ? 4'd8  : arm[9]    ? 4'd9  : arm[10]   ? 4'd10 : 4'd11;
wire [3:0]  v3 = arm[12]   ? 4'd12 : arm[13]   ? 4'd13 : arm[14]   ? 4'd14 : 4'd15;
wire [3:0]  sel  = |arm[3:0]   ? v0
                 : |arm[7:4]   ? v1
                 : |arm[11:8]  ? v2
                 : |arm[15:12] ? v3
                 : 4'd0;
wire [3:0]  vec_nx = sel ^ VEC_BIAS;

assign pin_out   = {16'h0000, out_r & dir_r};
assign level_any = |(pend & ~ie_r & changed);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bus_rdata  <= 32'h00000000;
        pend       <= 16'h0000;
        dir_r      <= 16'h0000;
        pol_r      <= 16'hFFFF;
        ie_r       <= 16'h0000;
        out_r      <= 16'h0000;
        sync_meta  <= 16'h0000;
        sync_q     <= 16'h0000;
        sync_d     <= 16'hFFFF;
        mode_g     <= 1'b0;
        irq_active <= 1'b0;
        irq_vec    <= 4'h0;
        sync_idx   <= 2'd0;
        storm      <= 1'b0;
        acked      <= 1'b0;
        set_evts   <= 5'd0;
        w1c_evts   <= 4'h0;
        err_count  <= 4'h0;
    end else if (clk_en) begin
        sync_d     <= sync_q;
        sync_idx   <= sync_step ? 2'd0 : (sync_idx + 2'd1);
        pend       <= pend_nx;
        ie_r       <= ie_next;
        mode_g     <= mode_next;
        irq_active <= |arm;
        irq_vec    <= vec_nx;
        if (sync_step) begin
            sync_meta <= pin_in[15:0];
            sync_q    <= sync_meta;
        end
        if (w_dir) begin
            dir_r <= wlo;
        end
        if (w_pol) begin
            pol_r <= wlo;
        end
        if (w_out) begin
            out_r <= wlo;
        end
        if (|newly) begin
            if (set_evts < EVT_SAT) begin
                set_evts <= set_evts + 5'd1;
            end
            if (set_evts + 5'd1 == EVT_SAT) begin
                storm <= 1'b1;
            end
        end
        if (w_pend && (wlo != 16'h0000)) begin
            if (w1c_evts < CNT_SAT) begin
                w1c_evts <= w1c_evts + 4'h1;
            end
        end
        if (bus_we && bad_addr) begin
            if (err_count < CNT_SAT) begin
                err_count <= err_count + 4'h1;
            end
        end
        if (bus_ack) begin
            acked <= 1'b1;
        end
        case (bus_addr)
            A_DIR:  bus_rdata <= {16'h0000, dir_r};
            A_POL:  bus_rdata <= {16'h0000, pol_r};
            A_MIE:  bus_rdata <= {16'h0000, 11'h0, mode_g, ie_r[3:0]};
            A_PEND: bus_rdata <= {16'h0000, pend};
            A_OUT:  bus_rdata <= {16'h0000, out_r};
            A_STAT: bus_rdata <= {13'h0, err_count, w1c_evts, set_evts,
                                  irq_active, storm, acked, level_any, sync_idx};
            default: bus_rdata <= INVALID_RD;
        endcase
    end
end

endmodule
