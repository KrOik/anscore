// ============================================================================
// ISP-10 integral image / local statistics / mean-C adaptive threshold.
//
// Streaming raster core.  Every accepted input pixel produces exactly one
// output beat in raster order (same-size output, strict II=1 sustained):
// the per-pixel work is O(1) because window sums use a column accumulator
// plus a horizontal running sum rather than revisiting the window.
//
// Window contract: causal trailing rectangle, rows max(0,y-WH+1)..y and
// columns max(0,x-WW+1)..x; clipped at top/left edges only; the area output
// reports min(x+1,WW)*min(y+1,WH).  No padding and no look-ahead.
//
// Pipeline: stage A = input handshake captures the pixel and issues the
// synchronous line/accumulator reads; stage B = combinational update commits
// on the next advance edge (writebacks + output registers).  A stall holds
// every state element and the pending result, so markers never slip.
//
// Read/write schedule: all five state RAMs are read at the take edge for
// column x and written back at the commit edge for the same column.  For
// image width 1 the commit of row y and the read of row y+1 land on the same
// edge; last_* forwarding registers cover that single collision case
// (adjacent columns differ for any width >= 2, so it cannot fire otherwise).
// ============================================================================
module integral_stats #(
    parameter BITS       = 8,
    parameter MAX_W      = 32,
    parameter MAX_H      = 24,
    parameter WIN_W_MAX  = 15,
    parameter WIN_H_MAX  = 15,
    // Derived widths; documented bounds, override only to mirror the formulas.
    // Clamped intermediates keep elaboration alive for illegal static params
    // so the initial parameter check reports them instead of a compile error.
    parameter MPX  = (BITS<1) ? 1 : ((1<<BITS)-1),
    parameter FP   = (MAX_W<1 || MAX_H<1 || MAX_W*MAX_H>65536) ? 1 : MAX_W*MAX_H,
    parameter WWM_ = (WIN_W_MAX<1) ? 1 : WIN_W_MAX,
    parameter WHM_ = (WIN_H_MAX<1) ? 1 : WIN_H_MAX,
    parameter IW   = $clog2(FP*MPX+1),
    parameter ISW  = IW + 2*BITS,
    parameter CSW  = $clog2(WHM_*MPX+1),
    parameter CQW  = CSW + BITS,
    parameter WSW  = $clog2(WWM_*WHM_*MPX+1),
    parameter WSSW = WSW + BITS,
    parameter AW   = $clog2(WWM_*WHM_+1),
    parameter XW   = (MAX_W<2) ? 1 : $clog2(MAX_W),
    parameter YW   = (MAX_H<2) ? 1 : $clog2(MAX_H),
    parameter CWX  = (MAX_W<1) ? 1 : $clog2(MAX_W+1),
    parameter CWY  = (MAX_H<1) ? 1 : $clog2(MAX_H+1),
    parameter FW   = $clog2(FP+1),
    parameter VW   = (2*BITS<1) ? 1 : 2*BITS
)(
    input  wire clk, rst_n,
    // Pixel stream: tuser = SOF (first pixel of frame), tlast = EOL.
    input  wire [BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    // Output stream: m_tdata = binarized image (all-ones or zero).
    output reg [BITS-1:0] m_tdata,
    output reg m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    // Sideband statistics, valid while m_tvalid (not separately backpressured).
    output reg [IW-1:0]   m_isum,
    output reg [ISW-1:0]  m_isq,
    output reg [WSW-1:0]  m_wsum,
    output reg [WSSW-1:0] m_wsq,
    output reg [AW-1:0]   m_area,
    output reg [BITS-1:0] m_mean,
    output reg [VW-1:0]   m_var,
    // Atomic configuration; accepted only between frames.
    input  wire cfg_valid, output wire cfg_ready,
    input  wire [CWX-1:0] cfg_img_w,
    input  wire [CWY-1:0] cfg_img_h,
    input  wire [3:0] cfg_win_w, cfg_win_h,
    input  wire signed [7:0] cfg_c,
    output reg cfg_done, cfg_error,
    output reg marker_error,
    output wire busy
);
    localparam EW4 = (XW > 4) ? XW : 4;
    localparam EH4 = (YW > 4) ? YW : 4;

    reg  [CWX-1:0] img_w;
    reg  [CWY-1:0] img_h;
    reg  [3:0] win_w, win_h;
    reg  signed [7:0] coff;
    reg  [XW-1:0] x;
    reg  [YW-1:0] y;
    reg  [3:0] bank;
    reg  [FW-1:0] pdcnt;   // accepted but not yet emitted pixels
    reg  fopen;            // frame inputs started but not completed
    reg  pend;
    reg  [BITS-1:0]   cap_p;
    reg  [2*BITS-1:0] cap_p2;
    reg  [XW-1:0] cap_x;
    reg  [YW-1:0] cap_y;
    reg  [3:0] cap_bank;
    reg  cap_u, cap_l;
    reg  [IW-1:0]   rsum_acc;
    reg  [ISW-1:0]  rsq_acc;
    reg  [WSW-1:0]  wsum_acc;
    reg  [WSSW-1:0] wsq_acc;
    reg  [AW-1:0]   area_acc;
    reg  [CSW-1:0] d_csum [0:WIN_W_MAX-1];
    reg  [CQW-1:0] d_csq  [0:WIN_W_MAX-1];
    reg  last_v;
    reg  [XW-1:0]  last_addr;
    reg  [IW-1:0]  last_i;
    reg  [ISW-1:0] last_iq;
    reg  [CSW-1:0] last_cs;
    reg  [CQW-1:0] last_csq;

    wire advance = !m_tvalid || m_tready;
    assign busy = fopen | (pdcnt != {FW{1'b0}});
    assign cfg_ready = rst_n && !busy;
    assign s_tready  = rst_n && advance && !(cfg_valid && cfg_ready);
    wire take = s_tvalid && s_tready;
    wire ouths = m_tvalid && m_tready;
    wire [2*BITS-1:0] p2_in = s_tdata * s_tdata;
    wire [CWX-1:0] w_last = img_w - 1'b1;
    wire [CWY-1:0] h_last = img_h - 1'b1;

    // ---- pixel history banks: WIN_H_MAX rotating rows of {p^2, p} ----------
    wire [WIN_H_MAX*3*BITS-1:0] pq_all;
    genvar gb;
    generate for (gb = 0; gb < WIN_H_MAX; gb = gb + 1) begin: pbanks
        (* ram_style="block" *) reg [3*BITS-1:0] mem [0:MAX_W-1];
        reg  [3*BITS-1:0] q;
        always @(posedge clk) if (take) begin
            q <= mem[x];                       // leaving pixel, read-before-write
            if (bank == gb) mem[x] <= {p2_in, s_tdata};
        end
        assign pq_all[gb*3*BITS +: 3*BITS] = q;
    end endgenerate

    // ---- column accumulators and previous-row integral storage -------------
    (* ram_style="block" *) reg [CSW-1:0]  cmem  [0:MAX_W-1];
    (* ram_style="block" *) reg [CQW-1:0]  cmem2 [0:MAX_W-1];
    (* ram_style="block" *) reg [IW-1:0]   imem  [0:MAX_W-1];
    (* ram_style="block" *) reg [ISW-1:0]  imem2 [0:MAX_W-1];
    reg  [CSW-1:0] cq;
    reg  [CQW-1:0] cq2;
    reg  [IW-1:0]  iq;
    reg  [ISW-1:0] iq2;
    always @(posedge clk) if (take) begin
        cq  <= cmem[x];
        cq2 <= cmem2[x];
        iq  <= imem[x];
        iq2 <= imem2[x];
    end

    // ------------------ stage-B combinational update ------------------------
    wire [3*BITS-1:0] pq = pq_all[cap_bank*3*BITS +: 3*BITS];
    wire [EH4:0] cap_y_e = {1'b0, cap_y};
    wire [EH4:0] win_h_e = {{(EH4-3){1'b0}}, win_h};
    wire lv = cap_y_e >= win_h_e;              // leaving pixel exists (y >= WH)
    wire use_fwd = last_v && (last_addr == cap_x);
    wire [CSW-1:0]  col_prev  = use_fwd ? last_cs : cq;
    wire [CQW-1:0]  col_prev2 = use_fwd ? last_csq : cq2;
    wire [IW-1:0]   i_prev    = use_fwd ? last_i : iq;
    wire [ISW-1:0]  i_prev2   = use_fwd ? last_iq : iq2;
    wire [BITS-1:0]   old_p  = lv ? pq[BITS-1:0]      : {BITS{1'b0}};
    wire [2*BITS-1:0] old_p2 = lv ? pq[3*BITS-1:BITS] : {(2*BITS){1'b0}};
    wire first_row = (cap_y == {YW{1'b0}});
    wire first_col = (cap_x == {XW{1'b0}});
    wire [CSW-1:0]  cs_new  = (first_row ? {CSW{1'b0}} : col_prev)  + cap_p  - old_p;
    wire [CQW-1:0]  csq_new = (first_row ? {CQW{1'b0}} : col_prev2) + cap_p2 - old_p2;
    wire [IW-1:0]  rowsum_now = (first_col ? {IW{1'b0}}  : rsum_acc) + cap_p;
    wire [ISW-1:0] rowsq_now  = (first_col ? {ISW{1'b0}} : rsq_acc)  + cap_p2;
    wire [IW-1:0]  i_now  = (first_row ? {IW{1'b0}}  : i_prev)  + rowsum_now;
    wire [ISW-1:0] iq_now = (first_row ? {ISW{1'b0}} : i_prev2) + rowsq_now;
    wire [EW4:0] cap_x_e = {1'b0, cap_x};
    wire [EW4:0] win_w_e = {{(EW4-3){1'b0}}, win_w};
    wire sub_en = cap_x_e >= win_w_e;
    wire [CSW-1:0] tail  = d_csum[win_w - 1'b1];
    wire [CQW-1:0] tail2 = d_csq[win_w - 1'b1];
    wire [WSW-1:0]  wsum_now = (first_col ? {WSW{1'b0}}  : wsum_acc)
                             + cs_new  - (sub_en ? tail  : {CSW{1'b0}});
    wire [WSSW-1:0] wsq_now = (first_col ? {WSSW{1'b0}} : wsq_acc)
                             + csq_new - (sub_en ? tail2 : {CQW{1'b0}});
    // Window area min(x+1,WW)*min(y+1,WH) accumulated without a multiplier:
    // it grows by ay each column while x < WW, then holds.
    wire [EH4:0] yp1 = cap_y_e + 1'b1;
    wire [3:0] ay = (yp1 >= win_h_e) ? win_h : yp1[3:0];
    wire [AW-1:0] ay_e = {{(AW-4){1'b0}}, ay};
    wire grow = !first_col && (cap_x_e < win_w_e);
    wire [AW-1:0] area_now = first_col ? ay_e
                          : (grow ? area_acc + ay_e : area_acc);
    wire bin_w;
    wire [BITS-1:0] mean_w;
    wire [VW-1:0] var_w;
    adaptive_threshold #(.BITS(BITS), .SW(WSW), .SQW(WSSW), .AW(AW), .VW(VW)) thr (
        .wsum(wsum_now), .wsq(wsq_now), .area(area_now),
        .pixel(cap_p), .c(coff),
        .bin_o(bin_w), .mean_o(mean_w), .var_o(var_w)
    );

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            img_w <= MAX_W; img_h <= MAX_H;
            win_w <= 3; win_h <= 3; coff <= 0;
            x <= 0; y <= 0; bank <= 0; pdcnt <= 0; fopen <= 0; pend <= 0;
            rsum_acc <= 0; rsq_acc <= 0; wsum_acc <= 0; wsq_acc <= 0;
            area_acc <= 0;
            last_v <= 0; last_addr <= 0;
            m_tvalid <= 0; m_tuser <= 0; m_tlast <= 0; m_tdata <= 0;
            m_isum <= 0; m_isq <= 0; m_wsum <= 0; m_wsq <= 0;
            m_area <= 0; m_mean <= 0; m_var <= 0;
            cfg_done <= 0; cfg_error <= 0; marker_error <= 0;
        end else begin
            cfg_done <= 0; cfg_error <= 0;
            if (cfg_valid && cfg_ready) begin
                if (cfg_img_w < 1 || cfg_img_w > MAX_W ||
                    cfg_img_h < 1 || cfg_img_h > MAX_H ||
                    cfg_win_w < 1 || cfg_win_w > WIN_W_MAX ||
                    cfg_win_h < 1 || cfg_win_h > WIN_H_MAX) begin
                    cfg_error <= 1;               // reject all fields
                end else begin
                    img_w <= cfg_img_w; img_h <= cfg_img_h;
                    win_w <= cfg_win_w; win_h <= cfg_win_h;
                    coff <= cfg_c; cfg_done <= 1;
                end
            end
            // Outstanding-pixel debt: +1 per accepted input, -1 per emitted
            // output.  Exactly one output is produced per input, so the debt
            // stays inside the pipeline depth; fopen keeps busy asserted while
            // a frame's inputs are incomplete (mid-frame input gaps).
            pdcnt <= pdcnt + {{(FW-1){1'b0}}, take} - {{(FW-1){1'b0}}, ouths};
            if (take) begin
                if (x == {XW{1'b0}} && y == {YW{1'b0}}) fopen <= 1;
                if (x == w_last && y == h_last) fopen <= 0;
            end
            if (advance) begin
                pend <= take;
                m_tvalid <= pend;
                if (take) begin
                    cap_p <= s_tdata; cap_p2 <= p2_in;
                    cap_x <= x; cap_y <= y; cap_bank <= bank;
                    cap_u <= s_tuser; cap_l <= s_tlast;
                    if (s_tuser != ((x == {XW{1'b0}}) && (y == {YW{1'b0}})) ||
                        s_tlast != (x == w_last))
                        marker_error <= 1;
                    if (x == w_last) begin
                        x <= 0;
                        if (y == h_last) begin
                            y <= 0; bank <= 0;
                        end else begin
                            y <= y + 1'b1;
                            bank <= (bank == win_h - 1'b1) ? 4'd0 : bank + 1'b1;
                        end
                    end else x <= x + 1'b1;
                end
                if (pend) begin
                    imem[cap_x]  <= i_now;
                    imem2[cap_x] <= iq_now;
                    cmem[cap_x]  <= cs_new;
                    cmem2[cap_x] <= csq_new;
                    last_v <= 1; last_addr <= cap_x;
                    last_i <= i_now; last_iq <= iq_now;
                    last_cs <= cs_new; last_csq <= csq_new;
                    d_csum[0] <= cs_new;
                    d_csq[0]  <= csq_new;
                    for (k = 1; k < WIN_W_MAX; k = k + 1) begin
                        d_csum[k] <= d_csum[k-1];
                        d_csq[k]  <= d_csq[k-1];
                    end
                    rsum_acc <= rowsum_now; rsq_acc <= rowsq_now;
                    wsum_acc <= wsum_now; wsq_acc <= wsq_now;
                    area_acc <= area_now;
                    m_tdata <= bin_w ? {BITS{1'b1}} : {BITS{1'b0}};
                    m_mean  <= mean_w;
                    m_var   <= var_w;
                    m_area  <= area_now;
                    m_wsum  <= wsum_now;
                    m_wsq   <= wsq_now;
                    m_isum  <= i_now;
                    m_isq   <= iq_now;
                    m_tuser <= cap_u;
                    m_tlast <= cap_l;
                end
            end
        end
    end

    initial begin
        if ((BITS != 8 && BITS != 10) || MAX_W < 1 || MAX_H < 1 ||
            WIN_W_MAX < 1 || WIN_W_MAX > 15 || WIN_H_MAX < 1 || WIN_H_MAX > 15 ||
            MAX_W * MAX_H > 65536)
            $fatal(1, "unsupported integral_stats parameters");
    end
endmodule
