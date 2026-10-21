// ============================================================================
// canny_nms -- wave2 idx7 (NMS): non-maximum suppression along the gradient
// direction, second stage of the Canny edge-detector chain.
//
//   Input  : magnitude stream `pix`[7:0] + direction stream `dir`[1:0]
//            (the canny_grad output pair), qualified by pix_valid.
//            new_line is accepted for contract symmetry but ignored: a frame
//            is exactly IMG_W*IMG_H valid pixels, so BOTH stream conventions
//            work (dedicated new_line beats or nl flag on the first pixel).
//            Extra pixels while a frame is being read out are dropped.
//   Output : thinned magnitude stream pix_out[7:0] (centre kept iff it is
//            >= BOTH directional neighbours, ties keep), out_valid + nl_out
//            flag (first pixel of each output row), done.
//
//   Architecture: frame buffer, not a streaming line buffer.  Input pixels
//   are written into two w2_dpram banks (mag x1, dir x1) at sequential
//   addresses; once IMG_W*IMG_H pixels are stored, two w2_win_rd readers
//   walk the frame in lockstep and emit edge-replicated (clamp) 3x3
//   windows of magnitude and direction.  This decouples input/output
//   timing completely -- any valid-beat cadence is accepted.
//
//   Direction -> compared neighbours (tap index i = r*3+c):
//     0 (~0deg)   : w3 (left)      w5 (right)
//     2 (~90deg)  : w1 (top)       w7 (bottom)
//     1 (~45deg)  : w0 (top-left)  w8 (bottom-right)
//     3 (~135deg) : w2 (top-right) w6 (bottom-left)
//
//   w2_win_rd is single-shot (its `done` never self-clears), so the readers
//   are held in reset during the write phase -- they re-arm cleanly for the
//   next frame whenever new pixels arrive after `done`.
//
//   RAM via w2_dpram only (T9).  All registers clk_en gated (T2).
// ============================================================================
module canny_nms #(
    parameter IMG_W = 32,                 // power of two (w2_win_rd)
    parameter IMG_H = 32
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,               // gradient magnitude
    input  wire [1:0]  dir,               // gradient direction class
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
    wire          rd_re,   rd_re2;
    wire [AW-1:0] rd_raddr, rd_raddr2;
    wire [7:0]    mag_q;
    wire [1:0]    dir_q;
    wire [71:0]   mag_win, dir_win;
    wire          mag_wv, dir_wv, rd_done, rd_done2;
    wire [4:0]    wx, wx2;
    wire [15:0]   wy, wy2;
    wire          rd_rst_n = rst_n && (st != ST_WR);  // readers idle in reset

    // ------------------------------------------------------------------
    // frame write: sequential store of (mag, dir); re-arm from ST_DN
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
    // frame RAMs + window readers (mag and dir in lockstep)
    // ------------------------------------------------------------------
    w2_dpram #(.W(8), .DEPTH(NPIX)) u_mag_ram (
        .clk(clk), .clk_en(clk_en),
        .we(wr_fire), .waddr(ram_waddr), .wdata(pix),
        .re(rd_re), .raddr(rd_raddr), .q(mag_q)
    );
    w2_dpram #(.W(2), .DEPTH(NPIX)) u_dir_ram (
        .clk(clk), .clk_en(clk_en),
        .we(wr_fire), .waddr(ram_waddr), .wdata(dir),
        .re(rd_re2), .raddr(rd_raddr2), .q(dir_q)
    );

    w2_win_rd #(.K(3), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_rd_mag (
        .clk(clk), .clk_en(clk_en), .rst_n(rd_rst_n), .start(rd_start),
        .re(rd_re), .raddr(rd_raddr), .q(mag_q),
        .win(mag_win), .win_valid(mag_wv), .win_x(wx), .win_y(wy),
        .done(rd_done)
    );
    w2_win_rd #(.K(3), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_rd_dir (
        .clk(clk), .clk_en(clk_en), .rst_n(rd_rst_n), .start(rd_start),
        .re(rd_re2), .raddr(rd_raddr2), .q({6'b0, dir_q}),
        .win(dir_win), .win_valid(dir_wv), .win_x(wx2), .win_y(wy2),
        .done(rd_done2)
    );

    // ------------------------------------------------------------------
    // NMS compare (combinational on the emitted windows, registered out)
    // ------------------------------------------------------------------
    wire [7:0] mw0 = mag_win[7:0],    mw1 = mag_win[15:8];
    wire [7:0] mw2 = mag_win[23:16],  mw3 = mag_win[31:24];
    wire [7:0] mw4 = mag_win[39:32],  mw5 = mag_win[47:40];
    wire [7:0] mw6 = mag_win[55:48],  mw7 = mag_win[63:56];
    wire [7:0] mw8 = mag_win[71:64];
    wire [1:0] dc  = dir_win[33:32];  // centre tap, low 2 bits

    reg [7:0] n1, n2;
    always @(*) begin
        case (dc)
            2'd0:    begin n1 = mw3; n2 = mw5; end
            2'd2:    begin n1 = mw1; n2 = mw7; end
            2'd1:    begin n1 = mw0; n2 = mw8; end
            default: begin n1 = mw2; n2 = mw6; end
        endcase
    end

    wire [7:0] nres = ((mw4 >= n1) && (mw4 >= n2)) ? mw4 : 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
            done      <= 1'b0;
        end else if (clk_en) begin
            pix_out   <= nres;
            out_valid <= mag_wv;
            nl_out    <= mag_wv && (wx == 5'd0);
            if ((st == ST_RD) && rd_done) done <= 1'b1;
            if ((st == ST_DN) && pix_valid) done <= 1'b0;  // re-arm
        end
    end
endmodule
