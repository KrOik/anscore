// ============================================================================
// ISP-07 Bayer demosaic -- bilinear RGGB/BGGR/GRBG/GBRG -> RGB reconstruction.
//
// Streaming raster core.  The input is a single-channel Bayer mosaic stream
// (tuser = SOF at frame pixel (0,0), tlast = EOL); the output is one
// {R,G,B} beat per input pixel in the same raster order, same markers.
//
// Window foundation: infra/window/stream_window_padded with K=3 and
// PAD_MODE=REPLICATE supplies a clamped-edge 3x3 neighborhood per output
// pixel.  tap(dx,dy) = frame[clamp(y+dy)][clamp(x+dx)], so boundary behavior
// is exactly edge replication -- no zeros, no special-case code.  The window
// modules are shared silicon-qualified infrastructure and are not modified.
//
// Bayer phase: the phase coordinate of frame pixel (x,y) is
//   pp = {yp, xp} = { (y + cfg_oy) & 1, (x + cfg_ox) & 1 }
// i.e. the pattern is anchored automatically at each frame's SOF pixel and
// cfg_ox/cfg_oy carry the *parity* of the frame origin inside the full sensor
// array (the post-ROI Bayer phase).  cfg_cfa selects the named pattern by the
// phase positions of its R and B sites:
//   cfa 0 RGGB: R at pp=00, B at pp=11     cfa 1 BGGR: R at 11, B at 00
//   cfa 2 GRBG: R at pp=01, B at pp=10     cfa 3 GBRG: R at 10, B at 01
// (B site phase is always the diagonal opposite of R: bph = rph ^ 2'b11.)
//
// Bilinear kernel (truncating averages -- floor, no rounding term):
//   R site : R=c              G=(up+dn+lf+rt)>>2   B=(tl+tr+bl+br)>>2
//   B site : B=c              G=(up+dn+lf+rt)>>2   R=(tl+tr+bl+br)>>2
//   G site : G=c; the non-G channel found on the horizontal axis uses
//            (lf+rt)>>1, the one on the vertical axis uses (up+dn)>>1.
// For a G site the horizontal-neighbor color is the site color at phase
// {yp,~xp}; whichever of R/B it is selects the axis for each channel.
// With replicated edges these rules degenerate to 1..4 distinct samples per
// average exactly as the model specifies.
//
// Pipeline: the window engine emits a beat; the demosaic result is computed
// combinationally and registered into the output stream one cycle later
// (service latency 1).  Stalls hold every state element: the window core
// only advances when the output register can accept.
// ============================================================================
module bayer_demosaic #(
    parameter BITS   = 8,
    parameter WIDTH  = 32,
    parameter HEIGHT = 24,
    // Derived widths; documented bounds, override only to mirror formulas.
    parameter XW = (WIDTH < 2) ? 1 : $clog2(WIDTH),
    parameter YW = (HEIGHT < 2) ? 1 : $clog2(HEIGHT),
    parameter CW = $clog2(WIDTH * HEIGHT + 1)
)(
    input  wire clk, rst_n,
    // Bayer mosaic input: tuser = SOF (first pixel of frame), tlast = EOL.
    input  wire [BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    // RGB output: m_tdata = {R, G, B}, one beat per input pixel.
    output reg  [3*BITS-1:0] m_tdata,
    output reg  m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    // Atomic configuration; accepted only between frames.
    input  wire cfg_valid, output wire cfg_ready,
    input  wire [1:0] cfg_cfa,        // 0=RGGB 1=BGGR 2=GRBG 3=GBRG
    input  wire cfg_ox, cfg_oy,       // frame-origin parity in sensor coords
    input  wire [3:0] cfg_reserved,   // must be 0
    output reg  cfg_done, cfg_error,
    output wire marker_error,
    output reg  busy
);
    localparam NP = WIDTH * HEIGHT;

    // ------------------------- window foundation ---------------------------
    reg  [CW-1:0] ins, outs;
    reg  [1:0] cfa;
    reg  cox, coy;
    wire [9*BITS-1:0] wd;
    wire wv, wu, wl, wr, win_err;
    wire wadvance = !m_tvalid || m_tready;      // output stage can accept
    assign cfg_ready = rst_n && !busy;
    wire allow = rst_n && (ins < NP) && !(cfg_valid && cfg_ready);
    assign s_tready = allow && wr;
    wire take = s_tvalid && s_tready;
    wire wad  = wv && wadvance;                 // window beat accepted here

    stream_window_padded #(
        .DATA_WIDTH(BITS), .WIDTH(WIDTH), .HEIGHT(HEIGHT),
        .K(3), .PAD_MODE(1)                     // REPLICATE edges
    ) win (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid && allow),
        .s_tuser(s_tuser), .s_tlast(s_tlast), .s_tready(wr),
        .m_tdata(wd), .m_tvalid(wv), .m_tuser(wu), .m_tlast(wl),
        .m_tready(wadvance), .marker_error(win_err));

    // ------------------- output position / phase tracking ------------------
    // ox_cnt/oy_cnt track the (x,y) of the beat currently at the window
    // output.  fopen marks "a frame is in flight at the window output", so
    // SOF is expected exactly when fopen is 0.
    reg [XW-1:0] ox_cnt;
    reg [YW-1:0] oy_cnt;
    reg fopen, align_err;
    assign marker_error = win_err | align_err;

    wire xp = ox_cnt[0] ^ cox;
    wire yp = oy_cnt[0] ^ coy;
    wire [1:0] pp = {yp, xp};

    // R-site phase per pattern; B is always the diagonal opposite.
    reg [1:0] rph;
    always @* begin
        case (cfa)
            2'd0: rph = 2'b00;   // RGGB
            2'd1: rph = 2'b11;   // BGGR
            2'd2: rph = 2'b01;   // GRBG
            default: rph = 2'b10;// GBRG
        endcase
    end
    wire [1:0] bph = rph ^ 2'b11;
    wire site_r = (pp == rph);
    wire site_b = (pp == bph);
    // For a G site: is the horizontal-axis neighbor color R?
    wire h_r = ({yp, ~xp} == rph);

    // --------------------------- taps / kernel -----------------------------
    wire [BITS-1:0] tl = wd[0*BITS +: BITS];
    wire [BITS-1:0] up = wd[1*BITS +: BITS];
    wire [BITS-1:0] tr = wd[2*BITS +: BITS];
    wire [BITS-1:0] lf = wd[3*BITS +: BITS];
    wire [BITS-1:0] c  = wd[4*BITS +: BITS];
    wire [BITS-1:0] rt = wd[5*BITS +: BITS];
    wire [BITS-1:0] bl = wd[6*BITS +: BITS];
    wire [BITS-1:0] dn = wd[7*BITS +: BITS];
    wire [BITS-1:0] br = wd[8*BITS +: BITS];

    wire [BITS+1:0] csum = {2'b00, up} + {2'b00, dn} + {2'b00, lf} + {2'b00, rt};
    wire [BITS+1:0] dsum = {2'b00, tl} + {2'b00, tr} + {2'b00, bl} + {2'b00, br};
    wire [BITS:0]   hsum = {1'b0, lf} + {1'b0, rt};
    wire [BITS:0]   vsum = {1'b0, up} + {1'b0, dn};
    wire [BITS-1:0] g4 = csum[BITS+1:2];   // truncating average x4
    wire [BITS-1:0] d4 = dsum[BITS+1:2];
    wire [BITS-1:0] h2 = hsum[BITS:1];     // truncating average x2
    wire [BITS-1:0] v2 = vsum[BITS:1];

    wire [BITS-1:0] r_o = site_r ? c : (site_b ? d4 : (h_r ? h2 : v2));
    wire [BITS-1:0] g_o = (site_r | site_b) ? g4 : c;
    wire [BITS-1:0] b_o = site_b ? c : (site_r ? d4 : (h_r ? v2 : h2));

    // --------------------------- sequential --------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            ins <= 0; outs <= 0; busy <= 0;
            cfa <= 0; cox <= 0; coy <= 0;
            ox_cnt <= 0; oy_cnt <= 0; fopen <= 0; align_err <= 0;
            m_tvalid <= 0; m_tuser <= 0; m_tlast <= 0; m_tdata <= 0;
            cfg_done <= 0; cfg_error <= 0;
        end else begin
            cfg_done <= 0; cfg_error <= 0;
            if (m_tready) m_tvalid <= 0;
            if (cfg_valid && cfg_ready) begin
                if (cfg_reserved != 4'd0) begin
                    cfg_error <= 1;             // reject all fields
                end else begin
                    cfa <= cfg_cfa; cox <= cfg_ox; coy <= cfg_oy;
                    cfg_done <= 1;
                end
            end
            if (take) begin
                ins <= ins + 1'b1;
                busy <= 1;
            end
            if (wad) begin
                m_tdata  <= {r_o, g_o, b_o};
                m_tuser  <= wu;
                m_tlast  <= wl;
                m_tvalid <= 1;
                // Marker alignment: SOF only on the first output beat of a
                // frame, EOL exactly on the last column.
                if (wu != !fopen)                    align_err <= 1;
                if (wl != (ox_cnt == WIDTH - 1))     align_err <= 1;
                if (!fopen) fopen <= 1;
                if (ox_cnt == WIDTH - 1) begin
                    ox_cnt <= {XW{1'b0}};
                    if (oy_cnt == HEIGHT - 1) begin
                        oy_cnt <= {YW{1'b0}};
                        fopen  <= 0;
                    end else begin
                        oy_cnt <= oy_cnt + 1'b1;
                    end
                end else begin
                    ox_cnt <= ox_cnt + 1'b1;
                end
            end
            if (m_tvalid && m_tready) begin
                if (outs == NP - 1) begin
                    ins <= 0; outs <= 0; busy <= 0;
                end else begin
                    outs <= outs + 1'b1;
                end
            end
        end
    end

    initial begin
        if ((BITS != 8 && BITS != 10) || WIDTH < 1 || HEIGHT < 1)
            $fatal(1, "unsupported bayer_demosaic parameters");
    end
endmodule
