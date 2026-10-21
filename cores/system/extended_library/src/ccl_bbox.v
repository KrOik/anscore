// ============================================================================
// ccl_bbox -- idx23 CCL: two-pass connected-component labelling on a 32x32
// binary frame with a <=63-entry label-equivalence union table.
//
// Flow (single frame, 4-connectivity).  All tables live in w2_dpram banks
// (T9) -- register arrays would cost ~5.6K LUT4 in mux/demux trees:
//   u_frame : W8 x NPIX  binary input image
//   u_lbl   : W8 x NPIX  per-pixel pass-1 labels
//   u_eq    : W12 x 64   union-find: {parent[5:0], root[5:0]} per label
//   u_sta   : W18 x 64   stats A: {2'b0, area[10:0], minx[4:0]}
//   u_stb   : W18 x 64   stats B: {3'b0, miny[4:0], maxx[4:0], maxy[4:0]}
//
//   S_LOAD : stream mask into u_frame (pix != 0 -> fg)
//   S_ZST  : zero the 64-entry stats tables (~64 beats)
//   S_P1A/B: raster pass 1, one pixel per 2 beats.  NORTH label read straight
//            from u_lbl (addr i-IMG_W); WEST label kept in a register
//            (avoids the RAM RAW hazard).  Cases:
//              fg & no nbr    -> new label, eq[top+1] = {top+1, top+1}
//              fg & one nbr   -> copy it
//              fg & w==n      -> copy it
//              fg & w!=n !=0  -> write min label, then union via S_UCH
//   S_UCH  : serialized root chase over u_eq port B (2 beats/step, chase ca
//            then cb), then S_UW writes parent[maxroot] <= minroot.
//   S_RSV  : per-label chase -> write eq[l] = {root, root} (path-compresses
//            parent AND stores canonical root in one write).
//   S_P2A..D: re-scan u_lbl; per fg pixel read eq[l].root -> r, RMW stats at
//            addr r (u_sta/u_stb in parallel); ncomp++ on first touch of a
//            root (area==0 -> bounds initialized with current pixel).
//   S_EMIT : [ncomp][ovf] then per label l=1..top with area>0 (ascending):
//            label, area_lo, area_hi, minx, miny, maxx, maxy   (7 bytes)
//   S_DONE : done=1 (holds)
//
// Documented simplifications (full equivalence resolution IS implemented):
//   * labels capped at MAXLBL=63; a fg pixel needing label 64+ is dropped
//     (written 0) and `ovf` set in the stream header.
//   * pass-1 stalls during serialized union chases (bounded by table depth).
//   * single eq read port -> ca/cb chased sequentially, not in parallel.
// All registers clk_en gated (T2).  No multipliers.
// `fidx`/`new_line` accepted for stream-contract uniformity but not used.
// ============================================================================
module ccl_bbox #(
    parameter IMG_W  = 32,
    parameter IMG_H  = 32,
    parameter MAXLBL = 63,
    parameter LW     = $clog2(IMG_W),
    parameter EW     = $clog2(MAXLBL+1),       // 6
    parameter AW     = $clog2(IMG_W*IMG_H)
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    input  wire [7:0]  fidx,
    output reg  [7:0]  out_byte,
    output reg         out_valid,
    output reg         done
);
    localparam NPIX = IMG_W*IMG_H;
    localparam RW   = $clog2(IMG_H);
    localparam S_LOAD=4'd0, S_ZST=4'd1, S_P1A=4'd2, S_P1B=4'd3, S_UCH=4'd4,
               S_UW=4'd5, S_RSV=4'd6, S_P2A=4'd7, S_P2B=4'd8, S_P2C=4'd9,
               S_P2D=4'd10, S_EMIT=4'd11, S_DONE=4'd12;

    reg  [3:0]     state;
    reg  [AW:0]    i;               // pixel cursor (reaches NPIX inclusive)
    reg  [AW-1:0]  ld_addr;
    reg  [EW-1:0]  lbl_top;
    reg            ovf;
    reg  [EW-1:0]  west_lbl;
    reg  [EW-1:0]  ca, cb;          // union chase cursors
    reg  [EW-1:0]  ra, rb;          // resolved roots of the union pair
    reg            uc_side;         // 0 = chasing ca, 1 = chasing cb
    reg            uc_ph;           // 0 = issue read, 1 = evaluate
    reg  [EW:0]    rl;              // resolve: current label (1..top)
    reg  [EW-1:0]  rc;              // resolve: chase cursor
    reg            rsv_ph;
    reg  [EW-1:0]  cur_r;           // pass-2: resolved root of current pixel
    reg  [7:0]     ncomp;
    reg  [6:0]     z_addr;          // stats-table zeroing cursor
    reg  [EW:0]    em_l;            // emit label index
    reg  [2:0]     em_j;            // emit byte index
    reg  [2:0]     em_ph;           // 0=ncomp,1=ovf,2=issue,3=label,4=body

    // ---------------- frame RAM --------------------------------------------
    wire [7:0] frame_q;
    w2_dpram #(.W(8), .DEPTH(NPIX), .AW(AW)) u_frame (
        .clk(clk), .clk_en(clk_en),
        .we((state == S_LOAD) && pix_valid), .waddr(ld_addr), .wdata(pix),
        .re(state == S_P1A), .raddr(i[AW-1:0]), .q(frame_q));

    // ---------------- label RAM --------------------------------------------
    wire [7:0]    lbl_q;
    wire        fg    = (frame_q != 8'd0);
    wire        x_is0 = (i[LW-1:0] == {LW{1'b0}});
    wire [EW-1:0] nq  = (i >= IMG_W) ? lbl_q[EW-1:0] : {EW{1'b0}};
    wire [EW-1:0] wq  = x_is0 ? {EW{1'b0}} : west_lbl;
    wire        un    = fg && (wq != 0) && (nq != 0) && (wq != nq);
    wire        newl  = fg && (wq == 0) && (nq == 0);
    wire        room  = (lbl_top < MAXLBL);
    wire [EW-1:0] lbl_new =
        !fg                                    ? {EW{1'b0}} :
        newl                                   ? (room ? lbl_top + 1'b1
                                                       : {EW{1'b0}}) :
        (wq == 0 || nq == 0 || wq == nq)       ? (wq | nq) :
        (wq < nq)                              ? wq : nq;
    wire [EW-1:0] ua = (wq < nq) ? wq : nq;
    wire [EW-1:0] ub = (wq < nq) ? nq : wq;

    wire          re_l = (state == S_P1A && i >= IMG_W) || (state == S_P2A);
    wire [AW-1:0] ra_l = (state == S_P2A) ? i[AW-1:0] : (i[AW-1:0] - IMG_W);
    w2_dpram #(.W(8), .DEPTH(NPIX), .AW(AW)) u_lbl (
        .clk(clk), .clk_en(clk_en),
        .we(state == S_P1B), .waddr(i[AW-1:0]),
        .wdata({{(8-EW){1'b0}}, lbl_new}),
        .re(re_l), .raddr(ra_l), .q(lbl_q));

    // ---------------- equivalence RAM {parent, root} -------------------------
    // port B reads: UCH chase / RSV chase / P2 root lookup.
    // port A writes: P1B new-label init, UW union link, RSVW resolve writeback.
    wire          eq_issue = ((state == S_UCH) && !uc_ph) ||
                             ((state == S_RSV) && !rsv_ph) ||
                             (state == S_P2B && (lbl_q[EW-1:0] != 0));
    wire [EW-1:0] eq_ra = (state == S_UCH) ? (uc_side ? cb : ca) :
                          (state == S_RSV) ? rc : lbl_q[EW-1:0];
    wire [11:0]   eq_q;
    wire          eq_we  = (state == S_P1B && newl && room) ||
                          (state == S_UW) ||
                          (state == S_RSV && rsv_ph == 1'b1 &&
                           eq_q[11:EW] == rc);     // resolve commit beat
    wire [EW-1:0] eq_wa = (state == S_P1B) ? lbl_top + 1'b1 :
                          (state == S_UW)  ? ((ra < rb) ? rb : ra) : rl[EW-1:0];
    wire [11:0]   eq_wd = (state == S_P1B) ? {lbl_top + 1'b1, lbl_top + 1'b1} :
                          (state == S_UW)  ? {2{(ra < rb) ? ra : rb}}
                                           : {2{rc}};
    wire [EW-1:0] eq_par  = eq_q[11:EW];
    wire [EW-1:0] eq_root = eq_q[EW-1:0];
    w2_dpram #(.W(12), .DEPTH(MAXLBL+1), .AW(EW)) u_eq (
        .clk(clk), .clk_en(clk_en),
        .we(eq_we), .waddr(eq_wa), .wdata(eq_wd),
        .re(eq_issue), .raddr(eq_ra), .q(eq_q));

    // ---------------- stats RAMs ---------------------------------------------
    // read in S_P2C (root lookup) and S_EMIT (record readout);
    // write in S_ZST (zeroing) and S_P2D (RMW commit).
    wire          st_issue = (state == S_P2C) ||
                             (state == S_EMIT && em_ph == 3'd2);
    // P2C issues the read at eq_root (cur_r is only registered at end of P2C)
    wire [EW-1:0] st_ra = (state == S_EMIT) ? em_l[EW-1:0] : eq_root;
    wire          st_we = (state == S_ZST) || (state == S_P2D);
    wire [EW-1:0] st_wa = (state == S_ZST) ? z_addr[EW-1:0] : cur_r;
    wire [17:0]   sa_q, sb_q;

    // stats read fields (valid one beat after st_issue)
    wire [10:0]   a_area = sa_q[15:5];
    wire [LW-1:0] a_minx = sa_q[LW-1:0];
    wire [RW-1:0] a_miny = sb_q[14:10];
    wire [LW-1:0] a_maxx = sb_q[9:5];
    wire [RW-1:0] a_maxy = sb_q[4:0];
    wire          first_t = (a_area == 11'd0);

    // updated stats for the current pixel (i) -- comb, evaluated in S_P2D
    wire [LW-1:0] c_x = i[LW-1:0];
    wire [RW-1:0] c_y = i[AW-1:LW];
    wire [10:0]   n_area = first_t ? 11'd1 : (a_area + 11'd1);
    wire [LW-1:0] n_minx = (first_t || c_x < a_minx) ? c_x : a_minx;
    wire [LW-1:0] n_maxx = (first_t || c_x > a_maxx) ? c_x : a_maxx;
    wire [RW-1:0] n_miny = (first_t || c_y < a_miny) ? c_y : a_miny;
    wire [RW-1:0] n_maxy = (first_t || c_y > a_maxy) ? c_y : a_maxy;
    wire [17:0]   st_wa_d = {2'b00, n_area, n_minx};
    wire [17:0]   st_wb_d = {3'b000, n_miny, n_maxx, n_maxy};

    w2_dpram #(.W(18), .DEPTH(MAXLBL+1), .AW(EW)) u_sta (
        .clk(clk), .clk_en(clk_en),
        .we(st_we), .waddr(st_wa),
        .wdata((state == S_ZST) ? 18'd0 : st_wa_d),
        .re(st_issue), .raddr(st_ra), .q(sa_q));
    w2_dpram #(.W(18), .DEPTH(MAXLBL+1), .AW(EW)) u_stb (
        .clk(clk), .clk_en(clk_en),
        .we(st_we), .waddr(st_wa),
        .wdata((state == S_ZST) ? 18'd0 : st_wb_d),
        .re(st_issue), .raddr(st_ra), .q(sb_q));

    // ---------------- sequential core ---------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_LOAD;
            i        <= {(AW+1){1'b0}};
            ld_addr  <= {AW{1'b0}};
            lbl_top  <= {EW{1'b0}};
            ovf      <= 1'b0;
            west_lbl <= {EW{1'b0}};
            ca       <= {EW{1'b0}};  cb <= {EW{1'b0}};
            ra       <= {EW{1'b0}};  rb <= {EW{1'b0}};
            uc_side  <= 1'b0;        uc_ph <= 1'b0;
            rl       <= {(EW+1){1'b0}}; rc <= {EW{1'b0}};
            rsv_ph   <= 1'b0;
            cur_r    <= {EW{1'b0}};
            ncomp    <= 8'd0;
            z_addr   <= 7'd0;
            em_l     <= {(EW+1){1'b0}}; em_j <= 3'd0; em_ph <= 3'd0;
            out_byte <= 8'd0;
            out_valid<= 1'b0;
            done     <= 1'b0;
        end else if (clk_en) begin
            out_valid <= 1'b0;
            case (state)
            // ---------------- load the binary frame -------------------------
            S_LOAD: begin
                if (pix_valid) begin
                    if (ld_addr == NPIX-1) begin
                        state  <= S_ZST;
                        z_addr <= 7'd0;
                    end
                    ld_addr <= ld_addr + 1'b1;
                end
            end
            // ---------------- zero stats tables ------------------------------
            S_ZST: begin
                if (z_addr == MAXLBL) begin
                    state <= S_P1A;
                    i     <= {(AW+1){1'b0}};
                end else begin
                    z_addr <= z_addr + 7'd1;
                end
            end
            // ---------------- pass 1: issue reads ----------------------------
            S_P1A: begin
                if (i == NPIX) begin
                    state  <= S_RSV;
                    rl     <= {{(EW){1'b0}}, 1'b1};
                    rc     <= {{(EW-1){1'b0}}, 1'b1};
                    rsv_ph <= 1'b0;
                end else begin
                    state <= S_P1B;      // frame_q/lbl_q valid next beat
                end
            end
            // ---------------- pass 1: decide + write label -------------------
            // (lbl RAM + eq RAM new-label writes commit this beat; comb)
            S_P1B: begin
                state    <= S_P1A;              // overridden by union branch
                west_lbl <= lbl_new;
                i        <= i + 1'b1;
                if (newl && room)
                    lbl_top <= lbl_top + 1'b1;
                if (newl && !room)
                    ovf <= 1'b1;                // label table full: drop px
                if (un) begin
                    ca      <= ua;
                    cb      <= ub;
                    uc_side <= 1'b0;
                    uc_ph   <= 1'b0;
                    state   <= S_UCH;
                end
            end
            // ---------------- union: serialized root chase -------------------
            S_UCH: begin
                if (!uc_ph) begin
                    uc_ph <= 1'b1;              // read of eq_ra issued
                end else begin
                    uc_ph <= 1'b0;
                    if (uc_side == 1'b0) begin
                        if (eq_par == ca) begin
                            ra      <= ca;      // root of ua found
                            uc_side <= 1'b1;    // now chase cb
                        end else begin
                            ca <= eq_par;
                        end
                    end else begin
                        if (eq_par == cb) begin
                            rb    <= cb;
                            state <= S_UW;
                        end else begin
                            cb <= eq_par;
                        end
                    end
                end
            end
            S_UW: begin                         // parent[maxroot] <= minroot
                state <= S_P1A;                 // (write commits via eq_we)
            end
            // ---------------- resolve: root[l] for all labels -----------------
            S_RSV: begin
                if (rl > {1'b0, lbl_top}) begin
                    state  <= S_P2A;
                    i      <= {(AW+1){1'b0}};
                    ncomp  <= 8'd0;
                end else if (!rsv_ph) begin
                    rsv_ph <= 1'b1;             // read of eq[rc] issued
                end else begin
                    if (eq_par == rc) begin
                        // commit eq[rl] = {rc, rc} via eq_we this beat
                        rl     <= rl + 1'b1;
                        rc     <= rl[EW-1:0] + 1'b1;
                        rsv_ph <= 1'b0;
                    end else begin
                        rc     <= eq_par;
                        rsv_ph <= 1'b0;
                    end
                end
            end
            // ---------------- pass 2: stats per root ---------------------------
            S_P2A: begin                        // issue lbl[i] read
                if (i == NPIX) begin
                    state <= S_EMIT;
                    em_ph <= 3'd0;
                end else begin
                    state <= S_P2B;
                end
            end
            S_P2B: begin                        // lbl_q valid; issue eq read
                if (lbl_q[EW-1:0] != 0) begin
                    state <= S_P2C;             // eq_q valid next beat
                end else begin
                    i     <= i + 1'b1;
                    state <= S_P2A;
                end
            end
            S_P2C: begin                        // eq_q valid; issue stat reads
                cur_r <= eq_root;
                state <= S_P2D;
            end
            S_P2D: begin                        // stat q valid; commit RMW
                if (first_t)
                    ncomp <= ncomp + 8'd1;
                i     <= i + 1'b1;
                state <= S_P2A;
            end
            // ---------------- emit table ---------------------------------------
            S_EMIT: begin
                case (em_ph)
                3'd0: begin
                    out_byte  <= ncomp;
                    out_valid <= 1'b1;
                    em_ph     <= 3'd1;
                end
                3'd1: begin
                    out_byte  <= {7'd0, ovf};
                    out_valid <= 1'b1;
                    em_ph     <= 3'd2;
                    em_l      <= {{(EW){1'b0}}, 1'b1};
                end
                3'd2: begin                     // issue stat read for em_l
                    if (em_l > {1'b0, lbl_top}) begin
                        state <= S_DONE;
                    end else begin
                        em_ph <= 3'd3;
                    end
                end
                3'd3: begin                     // stat q valid for em_l
                    if (a_area == 11'd0) begin
                        em_l  <= em_l + 1'b1;   // non-root label: skip
                        em_ph <= 3'd2;
                    end else begin
                        out_byte  <= {2'b00, em_l[5:0]};
                        out_valid <= 1'b1;
                        em_j      <= 3'd1;
                        em_ph     <= 3'd4;
                    end
                end
                default: begin                  // em_ph==4: record body
                    out_valid <= 1'b1;
                    case (em_j)
                    3'd1: out_byte <= a_area[7:0];
                    3'd2: out_byte <= {5'd0, a_area[10:8]};
                    3'd3: out_byte <= {{(8-LW){1'b0}}, a_minx};
                    3'd4: out_byte <= {{(8-RW){1'b0}}, a_miny};
                    3'd5: out_byte <= {{(8-LW){1'b0}}, a_maxx};
                    default: out_byte <= {{(8-RW){1'b0}}, a_maxy};
                    endcase
                    if (em_j == 3'd6) begin
                        em_j  <= 3'd0;
                        em_l  <= em_l + 1'b1;
                        em_ph <= 3'd2;
                    end else begin
                        em_j <= em_j + 3'd1;
                    end
                end
                endcase
            end
            default: begin                       // S_DONE
                done <= 1'b1;
            end
            endcase
        end
    end
endmodule
