// ============================================================================
// canny_hyst -- wave2 idx9 (HYS): 3x3 edge hysteresis, final stage of the
// Canny edge-detector chain.
//
//   Input  : 2-bit class stream `cls` (0 none / 1 weak / 2 strong, the
//            canny_dth output), qualified by pix_valid.  new_line is
//            accepted for contract symmetry but ignored: a frame is exactly
//            IMG_W*IMG_H valid pixels, so both stream conventions work.
//            Extra pixels while a frame is being read out are dropped.
//   Output : edge byte stream pix_out[7:0] = 8'hFF (edge) / 8'h00 (none),
//            out_valid + nl_out flag, done.
//
//   Rule (single-pass local propagation -- documented approximation):
//     centre strong            -> FF
//     centre weak  AND any of the 8 clamped 3x3 neighbours is strong -> FF
//     otherwise                -> 00
//   This is ONE local pass, not iterative flood-fill: a weak pixel promoted
//   by an adjacent strong does NOT promote further weak pixels in the same
//   frame (classic Canny edge tracing would).  Weak chains longer than one
//   pixel away from a strong seed are therefore cut; see doc/units_canny.md.
//
//   Architecture: same frame-buffer pattern as canny_nms -- class pixels
//   are written to one w2_dpram bank (W=2), then a w2_win_rd reader walks
//   the frame emitting edge-replicated (clamp) 3x3 class windows.
//   The reader is held in reset during the write phase so a new frame
//   re-arms it cleanly (w2_win_rd is single-shot after `done`).
//
//   RAM via w2_dpram only (T9).  All registers clk_en gated (T2).
// ============================================================================
module canny_hyst #(
    parameter IMG_W = 32,                 // power of two (w2_win_rd)
    parameter IMG_H = 32
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [1:0]  cls,               // 0 none / 1 weak / 2 strong
    input  wire        pix_valid,
    input  wire        new_line,          // ignored (frame = W*H valids)
    output reg  [7:0]  pix_out,
    output reg         out_valid,
    output reg         nl_out,
    output reg         done
);
    localparam NPIX = IMG_W * IMG_H;      // <= 1024 (one w2_dpram bank)
    localparam AW   = (NPIX > 1) ? $clog2(NPIX) : 1;

    localparam [1:0] ST_WR = 2'd0;        // collecting frame pixels
    localparam [1:0] ST_RD = 2'd1;        // window readout in progress
    localparam [1:0] ST_DN = 2'd2;        // frame done, idle until next

    reg  [1:0]    st;
    reg  [AW-1:0] waddr;
    reg           rd_start;

    // reader-side wires (declared early: the FSM below references rd_done)
    wire          rd_re;
    wire [AW-1:0] rd_raddr;
    wire [1:0]    cls_q;
    wire [71:0]   cls_win;
    wire          cw_v, rd_done;
    wire [4:0]    wx;
    wire [15:0]   wy;
    wire          rd_rst_n = rst_n && (st != ST_WR);  // reader idle in reset

    // ------------------------------------------------------------------
    // frame write: sequential store; re-arm from ST_DN on new pixels
    // ------------------------------------------------------------------
    wire wr_fire = pix_valid && (st != ST_RD);
    wire [AW-1:0] ram_waddr = (st == ST_DN) ? {AW{1'b0}} : waddr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= ST_WR;
            waddr    <= {AW{1'b0}};
            rd_start <= 1'b0;
        end else if (clk_en) begin
            rd_start <= 1'b0;
            case (st)
                ST_WR: if (pix_valid) begin
                    if (waddr == NPIX - 1) begin
                        st       <= ST_RD;
                        rd_start <= 1'b1;
                    end else begin
                        waddr <= waddr + 1'b1;
                    end
                end
                ST_RD: if (rd_done) st <= ST_DN;
                ST_DN: if (pix_valid) begin   // first pixel of next frame
                    st    <= ST_WR;
                    waddr <= {{AW-1{1'b0}}, 1'b1};
                end
                default: st <= ST_WR;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // frame RAM + window reader
    // ------------------------------------------------------------------
    w2_dpram #(.W(2), .DEPTH(NPIX)) u_cls_ram (
        .clk(clk), .clk_en(clk_en),
        .we(wr_fire), .waddr(ram_waddr), .wdata(cls),
        .re(rd_re), .raddr(rd_raddr), .q(cls_q)
    );

    w2_win_rd #(.K(3), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_rd (
        .clk(clk), .clk_en(clk_en), .rst_n(rd_rst_n), .start(rd_start),
        .re(rd_re), .raddr(rd_raddr), .q({6'b0, cls_q}),
        .win(cls_win), .win_valid(cw_v), .win_x(wx), .win_y(wy),
        .done(rd_done)
    );

    // ------------------------------------------------------------------
    // hysteresis rule (combinational on the emitted window, registered out)
    // ------------------------------------------------------------------
    wire [1:0] c0 = cls_win[1:0],    c1 = cls_win[9:8],   c2 = cls_win[17:16];
    wire [1:0] c3 = cls_win[25:24],  c4 = cls_win[33:32], c5 = cls_win[41:40];
    wire [1:0] c6 = cls_win[49:48],  c7 = cls_win[57:56], c8 = cls_win[65:64];

    wire any_strong = (c0 == 2'd2) || (c1 == 2'd2) || (c2 == 2'd2) ||
                      (c3 == 2'd2) || (c5 == 2'd2) || (c6 == 2'd2) ||
                      (c7 == 2'd2) || (c8 == 2'd2);

    wire [7:0] hres = (c4 == 2'd2) ? 8'hFF :
                      ((c4 == 2'd1) && any_strong) ? 8'hFF : 8'h00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
            done      <= 1'b0;
        end else if (clk_en) begin
            pix_out   <= hres;
            out_valid <= cw_v;
            nl_out    <= cw_v && (wx == 5'd0);
            if ((st == ST_RD) && rd_done) done <= 1'b1;
            if ((st == ST_DN) && pix_valid) done <= 1'b0;  // re-arm
        end
    end
endmodule
