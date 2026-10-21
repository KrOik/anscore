// ============================================================================
// DSP-14 stft_welch: streaming STFT / Welch power spectrum, N=64 frames.
//
// Chain: s_ signed16 -> 128x16 ring buffer (overlap H in {8,16,32,64})
//   -> window_mult (MAX_LOG2N=6, read-only reuse)
//   -> fft64 (sigproc serialized engine, 768-beat compute, read-only reuse)
//   -> mag_squared (read-only reuse)
//   -> internal 42-bit per-bin averager -> K-bin u32 records on m_.
//
// Single clk, synchronous active-low rst_n for all wrapper state.  The
// instantiated fft64/sig_sdp_ram/tw_rom_* carry a legacy clk_en/async-reset
// capable interface: the wrapper ties clk_en=1 and this core's rst_n must be
// applied synchronously.  See SPEC.md for the full rate/normalization
// contract.  Sustained input rate is bounded by H/T_frame (~H/912 clk);
// the buffer only decouples bursts, full is pure backpressure.
// ============================================================================
module stft_welch #(
    parameter integer RAM_REGS = 1   // sig_sdp_ram REGS: 1=reg array, 0=DPX9B
) (
    input  wire        clk,
    input  wire        rst_n,
    // sample input stream
    input  wire signed [15:0] s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    // PSD output stream: u32 bins, tuser={LAST,SOF}
    output reg  [31:0] m_tdata,
    output reg  [1:0]  m_tuser,
    output reg         m_tvalid,
    input  wire        m_tready,
    // atomic configuration
    input  wire        cfg_valid,
    output wire        cfg_ready,
    input  wire [2:0]  cfg_window,     // 0..4 (window_mult types)
    input  wire [1:0]  cfg_hop,        // H = 8 << cfg_hop
    input  wire        cfg_twosided,   // 0: K=33 bins, 1: K=64
    input  wire        cfg_avgmode,    // 0: block A=2**cfg_avg, 1: exp alpha
    input  wire [3:0]  cfg_avg,        // block: log2 A 0..8; exp: alpha 1..8
    input  wire signed [4:0] cfg_wshift, // -8..15
    input  wire [4:0]  cfg_pshift,     // 0..15
    output reg         cfg_done,
    output reg         cfg_error,
    // custom-window coefficient upload passthrough (window_mult contract)
    input  wire signed [17:0] coe_tdata,
    input  wire        coe_tvalid,
    output wire        coe_tready,
    // observability
    output reg         busy,
    output reg  [19:0] cnt_in,
    output reg  [15:0] cnt_frames,
    output reg  [15:0] cnt_recs,
    output reg         clip_sticky
);

// ---------------------------------------------------------------------------
// active configuration
// ---------------------------------------------------------------------------
reg [2:0]  c_window;
reg [1:0]  c_hop;
reg        c_two;
reg        c_amode;
reg [3:0]  c_avg;
reg signed [4:0] c_wsh;
reg [4:0]  c_psh;

wire [6:0] hop       = 7'd8 << c_hop;           // 8/16/32/64
wire [6:0] emit_last = c_two ? 7'd63 : 7'd32;   // last emitted bin index
wire [7:0] blk_a     = 8'd1 << c_avg;           // block average count 1..256

function automatic cfg_legal;
    input [2:0] w; input [1:0] h; input two; input am; input [3:0] av;
    input signed [4:0] ws; input [4:0] ps;
    begin
        cfg_legal = (w <= 3'd4) && (ps <= 5'd15) && (ws >= -5'sd8) &&
                    (am == 1'b0 ? (av <= 4'd8)
                                : (av >= 4'd1 && av <= 4'd8));
    end
endfunction

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
localparam [2:0] ST_IDLE  = 3'd0;
localparam [2:0] ST_LOAD  = 3'd1;
localparam [2:0] ST_START = 3'd2;
localparam [2:0] ST_RUN   = 3'd3;
localparam [2:0] ST_READ  = 3'd4;
localparam [2:0] ST_CFGW  = 3'd5;
localparam [2:0] ST_CFGM  = 3'd6;

reg [2:0] st;

// ---------------------------------------------------------------------------
// input ring buffer: 128 x signed16, write port A, read port B (sig_sdp_ram)
// ---------------------------------------------------------------------------
reg  [7:0]  fill;        // samples held relative to frame base (0..128)
reg  [6:0]  wptr;        // write pointer
reg  [6:0]  fbptr;       // current frame base pointer
wire        s_fire = s_tvalid && s_tready;
assign s_tready = rst_n && (fill < 8'd128) && !cfg_valid &&
                  (st != ST_CFGW) && (st != ST_CFGM);

// config commits only from IDLE with a drained output slot; priority over
// a ready frame (IDLE case checks cfg_valid first)
assign cfg_ready = rst_n && (st == ST_IDLE) && !m_tvalid;

// ---------------------------------------------------------------------------
// frame capture -> window -> fft load (ST_LOAD)
// ---------------------------------------------------------------------------
reg  [6:0] li;           // next read index to issue (0..64)
reg        ldv;          // buf_q holds a valid sample for the window input
reg  [6:0] ldcnt;        // fft loads accepted (0..64)

wire        ld_issue;                          // defined below
wire [6:0]  buf_raddr = fbptr + {1'b0, li[5:0]}; // mod-128 by width
wire signed [15:0] buf_q;

wire        win_sready, win_mv, win_mu;
wire signed [15:0] win_md;
wire        win_fire = ldv && win_sready;
assign ld_issue = (st == ST_LOAD) && (li < 7'd64) && (!ldv || win_fire);

sig_sdp_ram #(.WIDTH(16), .DEPTH(128), .REGS(RAM_REGS)) u_buf (
    .clk(clk), .clk_en(1'b1),
    .we(s_fire), .waddr(wptr), .wdata(s_tdata),
    .re(ld_issue), .raddr(buf_raddr), .q(buf_q)
);

wire        ld_en = win_mv && (st == ST_LOAD);
wire        frame_last_load = ld_en && (ldcnt == 7'd63);

window_mult #(.MAX_LOG2N(6)) u_win (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(buf_q), .s_tvalid(ldv), .s_tready(win_sready),
    .m_tdata(win_md), .m_tuser(win_mu), .m_tvalid(win_mv),
    .m_tready(1'b1),
    .cfg_valid(st == ST_CFGW), .cfg_ready(),
    .cfg_log2n(4'd6), .cfg_window(c_window), .cfg_shift(c_wsh),
    .cfg_done(), .cfg_error(),
    .coe_tdata(coe_tdata), .coe_tvalid(coe_tvalid),
    .coe_tready(coe_tready)
);

// ---------------------------------------------------------------------------
// fft readout state (declared before the fft instance that uses ri)
// ---------------------------------------------------------------------------
reg  [6:0] ri;           // next bin read index to issue (0..64)
reg        rdv;          // fft rd data + acc_q valid for mag input
reg  [5:0] rdv_bin;      // bin index belonging to the rdv beat
reg  [6:0] pk;           // bin index of power beats (0..64)
reg  [7:0] blk_idx;      // frame index inside block average (0..A-1)
reg  [63:0] accv;        // per-bin acc RAM validity for this config epoch

// ---------------------------------------------------------------------------
// fft64 instance (serialized; ld while !busy; rd natural order out)
// ---------------------------------------------------------------------------
wire        fft_start = (st == ST_START);
wire        fft_busy, fft_done;
wire signed [15:0] fft_rd_re, fft_rd_im;
wire        rd_issue;
wire        fft_rd_en = rd_issue;
wire [5:0]  fft_rd_addr = ri[5:0];

fft64 u_fft (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),
    .ld_en(ld_en), .ld_addr(ldcnt[5:0]),
    .ld_re(win_md), .ld_im(16'sd0),
    .start(fft_start), .busy(fft_busy), .done(fft_done),
    .rd_en(fft_rd_en), .rd_addr(fft_rd_addr),
    .rd_re(fft_rd_re), .rd_im(fft_rd_im)
);

// ---------------------------------------------------------------------------
// fft readout -> mag_squared -> averager (ST_READ)
// ---------------------------------------------------------------------------
wire        mag_sready, mag_mv, mag_mu;
wire [31:0] mag_md;
wire        mag_fire = rdv && mag_sready;
assign rd_issue = (st == ST_READ) && (ri < 7'd64) && (!rdv || mag_fire);

wire        p_ready = !m_tvalid || m_tready;
wire        p_fire  = mag_mv && p_ready;
wire        mag_advance = !mag_mv || p_ready;

mag_squared u_mag (
    .clk(clk), .rst_n(rst_n),
    .s_tdata({fft_rd_im, fft_rd_re}), .s_tvalid(rdv),
    .s_tready(mag_sready),
    .m_tdata(mag_md), .m_tuser(mag_mu), .m_tvalid(mag_mv),
    .m_tready(p_ready),
    .cfg_valid(st == ST_CFGM), .cfg_ready(), .cfg_shift(c_psh),
    .cfg_done(), .cfg_error()
);

// acc RAM: 64 x 42-bit signed, three sig_sdp_ram slices (port A write,
// port B read issued together with the fft readout address).
wire signed [41:0] acc_wdata;
wire [13:0] acc_q0, acc_q1, acc_q2;
wire signed [41:0] acc_q = {acc_q2, acc_q1, acc_q0};

sig_sdp_ram #(.WIDTH(14), .DEPTH(64), .REGS(RAM_REGS)) u_acc0 (
    .clk(clk), .clk_en(1'b1),
    .we(p_fire), .waddr(pk[5:0]), .wdata(acc_wdata[13:0]),
    .re(rd_issue), .raddr(ri[5:0]), .q(acc_q0));
sig_sdp_ram #(.WIDTH(14), .DEPTH(64), .REGS(RAM_REGS)) u_acc1 (
    .clk(clk), .clk_en(1'b1),
    .we(p_fire), .waddr(pk[5:0]), .wdata(acc_wdata[27:14]),
    .re(rd_issue), .raddr(ri[5:0]), .q(acc_q1));
sig_sdp_ram #(.WIDTH(14), .DEPTH(64), .REGS(RAM_REGS)) u_acc2 (
    .clk(clk), .clk_en(1'b1),
    .we(p_fire), .waddr(pk[5:0]), .wdata(acc_wdata[41:28]),
    .re(rd_issue), .raddr(ri[5:0]), .q(acc_q2));

// acc pipeline aligned with mag_squared's 4-edge input-to-valid latency
reg signed [41:0] accd [0:3];
wire signed [41:0] acc_cur = accv[rdv_bin] ? acc_q : 42'sd0;

// ---------------------------------------------------------------------------
// averager arithmetic (combinational result of p_fire for bin pk)
// ---------------------------------------------------------------------------
wire        blk_final = (c_amode == 1'b0) && (blk_idx == blk_a - 8'd1);

// unsigned RNE right shift on a 43-bit value
function [42:0] rne_u;
    input [42:0] v; input [5:0] k;
    reg [42:0] q, rem, half;
    begin
        q = v >> k;
        rem = v & ((43'd1 << k) - 43'd1);
        half = (k != 6'd0) ? (43'd1 << (k - 6'd1)) : 43'd0;
        if (k != 6'd0 && (rem > half || (rem == half && q[0])))
            q = q + 43'd1;
        rne_u = q;
    end
endfunction

wire signed [42:0] acc_e   = {accd[3][41], accd[3]};
wire signed [42:0] p_wide  = {11'd0, mag_md};
wire signed [42:0] sum_blk = acc_e + p_wide;                 // block acc_new
wire signed [42:0] d_exp   = {2'b00, mag_md, 8'b0} - acc_e;  // (P<<8)-S
wire signed [42:0] d_sh    = d_exp >>> c_avg;                // >>>alpha
wire signed [42:0] sum_exp = acc_e + d_sh;

wire signed [42:0] acc_new = (c_amode == 1'b0) ? sum_blk : sum_exp;
assign acc_wdata = ((c_amode == 1'b0) && blk_final)
                   ? 42'sd0 : acc_new[41:0];
wire [42:0]        avg_res = (c_amode == 1'b0)
                             ? rne_u({1'b0, acc_new[41:0]}, {2'b00, c_avg})
                             : rne_u({1'b0, acc_new[41:0]}, 6'd8);
wire [31:0]        avg_out = (avg_res > 43'd4294967295)
                             ? 32'hffffffff : avg_res[31:0];
wire        emit_en = p_fire && (pk <= emit_last) &&
                      ((c_amode == 1'b1) || blk_final);
wire        frame_end = p_fire && (pk == 7'd63);

always @(posedge clk) begin
    if (!rst_n) begin
        st <= ST_IDLE;
        c_window <= 3'd0; c_hop <= 2'd3; c_two <= 1'b0;
        c_amode <= 1'b0; c_avg <= 4'd0; c_wsh <= 5'sd0; c_psh <= 5'd0;
        fill <= 8'd0; wptr <= 7'd0; fbptr <= 7'd0;
        li <= 7'd0; ldv <= 1'b0; ldcnt <= 7'd0;
        ri <= 7'd0; rdv <= 1'b0; rdv_bin <= 6'd0;
        pk <= 7'd0; blk_idx <= 8'd0; accv <= 64'd0;
        accd[0] <= 42'sd0; accd[1] <= 42'sd0;
        accd[2] <= 42'sd0; accd[3] <= 42'sd0;
        m_tdata <= 32'd0; m_tuser <= 2'b00; m_tvalid <= 1'b0;
        cfg_done <= 1'b0; cfg_error <= 1'b0;
        busy <= 1'b0; cnt_in <= 20'd0; cnt_frames <= 16'd0;
        cnt_recs <= 16'd0; clip_sticky <= 1'b0;
    end else begin
        cfg_done <= 1'b0;
        cfg_error <= 1'b0;
        busy <= (st != ST_IDLE);

        // ---- output slot (m_tvalid is the slot flag; data holds on stall)
        if (m_tvalid && m_tready) m_tvalid <= 1'b0;
        if (emit_en) begin
            m_tvalid <= 1'b1;
            m_tdata  <= avg_out;
            m_tuser  <= {pk == emit_last, pk == 7'd0};
        end

        // ---- input capture ------------------------------------------------
        if (s_fire) begin
            wptr <= wptr + 7'd1;
            cnt_in <= cnt_in + 20'd1;
        end
        case ({s_fire, frame_end})
            2'b10: fill <= fill + 8'd1;
            2'b01: fill <= fill - {1'b0, hop};
            2'b11: fill <= fill + 8'd1 - {1'b0, hop};
            default: fill <= fill;
        endcase
        if (frame_end) begin
            fbptr <= fbptr + hop[6:0];
            cnt_frames <= cnt_frames + 16'd1;
            if (c_amode == 1'b0)
                blk_idx <= blk_final ? 8'd0 : blk_idx + 8'd1;
        end

        // ---- clip observation --------------------------------------------
        if ((win_mv && win_mu) || (p_fire && mag_mu))
            clip_sticky <= 1'b1;

        // ---- LOAD: buffer -> window -> fft --------------------------------
        if (ld_issue) begin
            li <= li + 7'd1;
            ldv <= 1'b1;
        end else if (win_fire) begin
            ldv <= 1'b0;
        end
        if (ld_en) ldcnt <= ldcnt + 7'd1;

        // ---- READ: fft -> mag -> acc/emit ---------------------------------
        if (rd_issue) begin
            ri <= ri + 7'd1;
            rdv <= 1'b1;
            rdv_bin <= ri[5:0];
        end else if (mag_fire) begin
            rdv <= 1'b0;
        end
        if (mag_advance) begin
            accd[0] <= mag_fire ? acc_cur : 42'sd0;
            accd[1] <= accd[0];
            accd[2] <= accd[1];
            accd[3] <= accd[2];
        end
        if (p_fire) begin
            accv[pk[5:0]] <= 1'b1;
            pk <= pk + 7'd1;
            if (emit_en && pk == emit_last)
                cnt_recs <= cnt_recs + 16'd1;
        end

        // ---- FSM ----------------------------------------------------------
        case (st)
            ST_IDLE: begin
                if (cfg_valid) begin
                    if (cfg_legal(cfg_window, cfg_hop, cfg_twosided,
                                  cfg_avgmode, cfg_avg, cfg_wshift,
                                  cfg_pshift)) begin
                        c_window <= cfg_window; c_hop <= cfg_hop;
                        c_two <= cfg_twosided; c_amode <= cfg_avgmode;
                        c_avg <= cfg_avg; c_wsh <= cfg_wshift;
                        c_psh <= cfg_pshift;
                        fill <= 8'd0; wptr <= 7'd0; fbptr <= 7'd0;
                        li <= 7'd0; ldv <= 1'b0; ldcnt <= 7'd0;
                        ri <= 7'd0; rdv <= 1'b0; rdv_bin <= 6'd0;
                        pk <= 7'd0; blk_idx <= 8'd0; accv <= 64'd0;
                        cnt_in <= 20'd0; cnt_frames <= 16'd0;
                        cnt_recs <= 16'd0; clip_sticky <= 1'b0;
                        st <= ST_CFGW;
                    end else begin
                        cfg_error <= 1'b1;
                    end
                end else if (fill >= 8'd64) begin
                    li <= 7'd0; ldv <= 1'b0; ldcnt <= 7'd0;
                    st <= ST_LOAD;
                end
            end
            ST_LOAD: if (frame_last_load) st <= ST_START;
            ST_START: st <= ST_RUN;
            ST_RUN: if (fft_done) begin
                ri <= 7'd0; rdv <= 1'b0; rdv_bin <= 6'd0; pk <= 7'd0;
                st <= ST_READ;
            end
            ST_READ: if (frame_end) st <= ST_IDLE;
            ST_CFGW: st <= ST_CFGM;
            ST_CFGM: begin
                cfg_done <= 1'b1;
                st <= ST_IDLE;
            end
            default: st <= ST_IDLE;
        endcase
    end
end

`ifndef SYNTHESIS
initial if (RAM_REGS != 0 && RAM_REGS != 1)
    $fatal(1, "stft_welch: RAM_REGS must be 0 or 1");
`endif
endmodule
