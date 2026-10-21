// 6x6-tap (36 source pixels) separable polyphase video scaler.
// Lanczos-3 kernel, 64 sub-pixel phases, runtime image dimensions.
//
// Architecture: input rows rotate over 7 synchronous line banks; a vertical
// 6-tap sweep produces one intermediate row per output row into a ping-pong
// row buffer; a horizontal 6-tap polyphase stage expands each intermediate
// row into output pixels held by a second ping-pong buffer; the drain stage
// re-marks SOF/EOL on the output stream. 36 input pixels contribute to every
// output pixel (6 vertical x 6 horizontal taps).
//
// Stream contract (cores/signal_processing/dsp_isp_library/infra/stream/README.md):
// single clock, synchronous active-low rst_n, s_/m_ tdata/tvalid/tready,
// tuser[0]=SOF, tlast=EOL. RGB888 packed in tdata[23:0] = {R,G,B}.
//
// Configuration: pulse cfg_valid with cfg_in_w/cfg_in_h/cfg_out_w/cfg_out_h
// while cfg_ready; an internal divider derives Q16.16 steps (2x28 cycles),
// then cfg_done pulses. cfg_ready only between frames. cfg_error latches on
// illegal dimensions or a step > 64.0 and clears on the next cfg attempt.
// marker_error latches on malformed SOF/EOL. busy covers the whole frame
// pipeline from input SOF to the last drained output beat.
module scale_poly6_stream #(parameter MAX_W=1920)(
    input wire clk, rst_n,
    input wire [23:0] s_tdata,
    input wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output reg [23:0] m_tdata,
    output reg m_tvalid, m_tuser, m_tlast,
    input wire m_tready,
    input wire cfg_valid, output wire cfg_ready,
    input wire [11:0] cfg_in_w, cfg_in_h, cfg_out_w, cfg_out_h,
    output reg cfg_done, cfg_error,
    output reg marker_error, output wire busy
);
    localparam AW = (MAX_W<2)?1:$clog2(MAX_W);

    // ------------------------------------------------------------------
    // Line banks: input row r resides in bank r%7. A vertical sweep reads
    // the 6 banks of rows L..L+5; residue (L+6)%7 is the only free bank and
    // may keep accepting the next input row while a sweep runs.
    // ------------------------------------------------------------------
    reg lb_rd;
    reg [AW-1:0] lb_addr;
    wire take;
    reg in_frame;
    reg [2:0] wbank;
    reg [11:0] in_x, in_y;
    wire [167:0] lbq;
    // Write position of the currently presented beat; (0,0)/bank0 at SOF.
    wire [11:0] wx = in_frame ? in_x : 12'd0;
    wire [11:0] wy = in_frame ? in_y : 12'd0;
    wire [2:0] wb = in_frame ? wbank : 3'd0;
    genvar gb;
    generate for(gb=0;gb<7;gb=gb+1) begin: lbank
        (* ram_style="block" *) reg [23:0] mem [0:MAX_W-1];
        reg [23:0] q;
        always @(posedge clk) begin
            if(lb_rd) q <= mem[lb_addr];
            if(take && wb==gb) mem[wx[AW-1:0]] <= s_tdata;
        end
        assign lbq[gb*24 +: 24] = q;
    end endgenerate

    // Intermediate row buffers, 12-bit/channel with 4 fractional bits.
    (* ram_style="block" *) reg [35:0] ib0 [0:MAX_W-1];
    (* ram_style="block" *) reg [35:0] ib1 [0:MAX_W-1];
    reg [35:0] ibq;
    reg ib_rd;
    reg [AW-1:0] ib_raddr;
    // Output row buffers, 8-bit/channel.
    (* ram_style="block" *) reg [23:0] ob0 [0:MAX_W-1];
    (* ram_style="block" *) reg [23:0] ob1 [0:MAX_W-1];

    // ------------------------------------------------------------------
    // Configuration and step divider (Q16.16, 28 iterations per axis).
    // ------------------------------------------------------------------
    reg [11:0] in_w, in_h, out_w, out_h;
    reg [31:0] sx_fp, sy_fp;
    reg cfg_ok;
    reg div_run, div_axis;
    reg [4:0] div_i;
    reg [27:0] div_num, div_quo;
    reg [28:0] div_rem;
    reg [11:0] div_den;
    reg frame_busy;
    assign cfg_ready = rst_n && !frame_busy && !div_run;
    wire cfg_fire = cfg_valid && cfg_ready;
    wire cfg_bad = (cfg_in_w==0)||(cfg_in_h==0)||(cfg_out_w==0)||(cfg_out_h==0)
                 ||(cfg_in_w>MAX_W)||(cfg_out_w>MAX_W);
    wire [28:0] div_ext = {div_rem[27:0], div_num[27]};
    wire div_sub = (div_ext >= {17'b0, div_den});
    always @(posedge clk) begin
        if(!rst_n) begin
            in_w<=0; in_h<=0; out_w<=0; out_h<=0;
            sx_fp<=0; sy_fp<=0; cfg_ok<=0;
            div_run<=0; div_axis<=0; div_i<=0;
            div_num<=0; div_quo<=0; div_rem<=0; div_den<=0;
            cfg_done<=0; cfg_error<=0;
        end else begin
            cfg_done<=0;
            if(cfg_fire) begin
                cfg_error<=0;
                if(cfg_bad) begin
                    cfg_error<=1; cfg_ok<=0; cfg_done<=1;
                end else begin
                    in_w<=cfg_in_w; in_h<=cfg_in_h;
                    out_w<=cfg_out_w; out_h<=cfg_out_h;
                    cfg_ok<=0;
                    div_run<=1; div_axis<=0; div_i<=27;
                    div_num<={cfg_in_w,16'b0}+{16'b0,cfg_out_w[11:1]};
                    div_den<=cfg_out_w;
                    div_quo<=0; div_rem<=0;
                end
            end else if(div_run) begin
                div_num <= {div_num[26:0],1'b0};
                div_rem <= div_sub ? div_ext-{17'b0,div_den} : div_ext;
                div_quo <= {div_quo[26:0], div_sub};
                if(div_i==0) begin
                    if(div_axis==0) begin
                        if({div_quo[26:0],div_sub} > 28'h400000) begin
                            cfg_error<=1; cfg_done<=1; div_run<=0;
                        end else begin
                            sx_fp<={4'b0,div_quo[26:0],div_sub};
                            div_axis<=1; div_i<=27;
                            div_num<={in_h,16'b0}+{16'b0,out_h[11:1]};
                            div_den<=out_h;
                            div_quo<=0; div_rem<=0;
                        end
                    end else begin
                        if({div_quo[26:0],div_sub} > 28'h400000) begin
                            cfg_error<=1;
                        end else begin
                            sy_fp<={4'b0,div_quo[26:0],div_sub};
                            cfg_ok<=1;
                        end
                        cfg_done<=1; div_run<=0;
                    end
                end else div_i<=div_i-1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Shared helpers and scheduling wires.
    // ------------------------------------------------------------------
    function [11:0] clamp_max;
        input signed [15:0] v; input [11:0] mx;
        begin clamp_max = (v<0)?12'd0:((v>$signed({1'b0,mx}))?mx:v[11:0]); end
    endfunction
    function [2:0] mod7;
        input [11:0] v;
        begin mod7 = v%7; end
    endfunction

    reg [11:0] oy;                  // next output row to produce
    reg signed [31:0] cy;           // output-row center, input coords, Q16.16
    wire signed [15:0] Ly = ((cy>>>16)-16'sd2);
    wire [11:0] R_eff = clamp_max(Ly+16'sd5, in_h-12'd1);
    wire [11:0] free_row = clamp_max(Ly+16'sd6, in_h);
    // frame_busy gates every output-row action: after a mid-idle cfg update
    // a stale oy < new out_h must not launch phantom sweeps between frames.
    wire outputs_left = frame_busy && (oy < out_h);
    wire vs_active;
    wire drain_in = in_frame && !outputs_left && (in_y < in_h);
    wire fill_in  = in_frame && outputs_left && !vs_active && (in_y <= R_eff);
    wire over_in  = in_frame && outputs_left && (in_y < in_h)
                    && (in_y == free_row);
    wire sof_ok   = !in_frame && !frame_busy && s_tuser;
    assign s_tready = rst_n && cfg_ok &&
                      (drain_in || fill_in || over_in || sof_ok);
    assign take = s_tvalid && s_tready;

    // ------------------------------------------------------------------
    // Vertical sweep registers and MAC.
    // ------------------------------------------------------------------
    localparam V_IDLE=1'b0, V_RUN=1'b1;
    reg vstate;
    reg [11:0] vx;                  // issue column
    reg [11:0] vwx;                 // write column (issued addr delayed)
    reg vpend;                      // lbq holds data for column vwx
    reg vp, hp;
    reg [1:0] ibuf_full;
    reg [5:0] vph;
    reg [17:0] vsel;                // 6 x 3-bit bank selects
    assign vs_active = (vstate!=V_IDLE);
    wire vs_can_start = outputs_left && (in_y > R_eff) && !ibuf_full[vp];
    wire [77:0] vcoef = scale_coef_row(vph);

    integer vt;
    reg [23:0] vpx;
    reg signed [13:0] vcf;
    reg signed [27:0] vacc_r, vacc_g, vacc_b;
    always @* begin
        vacc_r=0; vacc_g=0; vacc_b=0;
        for(vt=0;vt<6;vt=vt+1) begin
            vpx = lbq[vsel[vt*3 +: 3]*24 +: 24];
            vcf = $signed(vcoef[vt*13 +: 13]);
            vacc_r = vacc_r + $signed({1'b0,vpx[23:16]})*vcf;
            vacc_g = vacc_g + $signed({1'b0,vpx[15:8]})*vcf;
            vacc_b = vacc_b + $signed({1'b0,vpx[7:0]})*vcf;
        end
    end
    function [11:0] vclamp;
        input signed [27:0] a;
        reg signed [28:0] r;
        begin r = (a+29'sd64)>>>7; vclamp = (r<0)?0:((r>4095)?4095:r[11:0]); end
    endfunction
    wire [35:0] vres = {vclamp(vacc_r),vclamp(vacc_g),vclamp(vacc_b)};

    // ------------------------------------------------------------------
    // Horizontal stage registers and MAC.
    // ------------------------------------------------------------------
    localparam H_IDLE=1'b0, H_RUN=1'b1;
    reg hstate;
    reg hop, dp;
    reg [1:0] obuf_full;
    reg [11:0] ox;
    reg signed [31:0] cx;
    reg signed [15:0] h_ld, h_sv;
    reg h_pend;
    reg [35:0] hwin [0:5];
    wire signed [31:0] cx0 = ($signed(sx_fp)-32'sd65536)>>>1;
    wire signed [15:0] Lx = ((cx>>>16)-16'sd2);
    wire signed [15:0] Ln = (((cx+$signed({1'b0,sx_fp}))>>>16)-16'sd2);
    wire h_can_emit = (hstate==H_RUN) && (h_sv == Lx+16'sd6) && !h_pend;
    wire signed [15:0] h_target = h_can_emit ? Ln : Lx;
    wire h_issue = (hstate==H_RUN) && (h_ld <= h_target+16'sd5);
    wire [77:0] hcoef = scale_coef_row(cx[15:10]);

    integer ht;
    reg signed [13:0] hcf;
    reg signed [31:0] hacc_r, hacc_g, hacc_b;
    always @* begin
        hacc_r=0; hacc_g=0; hacc_b=0;
        for(ht=0;ht<6;ht=ht+1) begin
            hcf = $signed(hcoef[ht*13 +: 13]);
            hacc_r = hacc_r + $signed({1'b0,hwin[ht][35:24]})*hcf;
            hacc_g = hacc_g + $signed({1'b0,hwin[ht][23:12]})*hcf;
            hacc_b = hacc_b + $signed({1'b0,hwin[ht][11:0]})*hcf;
        end
    end
    function [7:0] hclamp;
        input signed [31:0] a;
        reg signed [32:0] r;
        begin
            r = (a+33'sd16384)>>>15;
            hclamp = (r<0)?0:((r>255)?255:r[7:0]);
        end
    endfunction
    wire [23:0] hres = {hclamp(hacc_r),hclamp(hacc_g),hclamp(hacc_b)};

    // ------------------------------------------------------------------
    // Output drain registers.
    // ------------------------------------------------------------------
    localparam D_IDLE=1'b0, D_ROW=1'b1;
    reg dstate;
    reg [11:0] dx, dsent, drow;
    reg d_sof;
    wire d_fetch = (dstate==D_ROW) && (dx<out_w) && (!m_tvalid || m_tready);
    assign busy = frame_busy;

    // ------------------------------------------------------------------
    // Single control block: every state register has exactly one writer.
    // ------------------------------------------------------------------
    integer hw;
    always @(posedge clk) begin
        if(!rst_n) begin
            in_frame<=0; in_x<=0; in_y<=0; wbank<=0; marker_error<=0;
            oy<=0; cy<=0;
            vstate<=V_IDLE; vx<=0; vwx<=0; vpend<=0; lb_rd<=0; lb_addr<=0;
            vp<=0; hp<=0; ibuf_full<=0; vph<=0; vsel<=0;
            ibq<=0; ib_rd<=0; ib_raddr<=0;
            hstate<=H_IDLE; hop<=0; dp<=0; obuf_full<=0; ox<=0; cx<=0;
            h_ld<=0; h_sv<=0; h_pend<=0;
            for(hw=0;hw<6;hw=hw+1) hwin[hw]<=0;
            dstate<=D_IDLE; dx<=0; dsent<=0; drow<=0; d_sof<=0;
            m_tdata<=0; m_tvalid<=0; m_tuser<=0; m_tlast<=0;
            frame_busy<=0;
        end else begin
            // -------- frame-level bookkeeping --------
            if(drow==out_h && !in_frame) frame_busy<=0;
            if(take && !in_frame) begin
                frame_busy<=1; d_sof<=1; drow<=0;
                oy<=0; cy<=($signed(sy_fp)-32'sd65536)>>>1;
                vp<=0; hp<=0; hop<=0; dp<=0;
                ibuf_full<=0; obuf_full<=0;
            end

            // -------- input stream / markers --------
            // Current beat position is (wx, row in_y) with bank wb; at SOF
            // (in_frame=0) it is implicitly (0,0)/bank0.  in_y keeps counting
            // to in_h when the last pixel lands so "all rows received" stays
            // visible to the vertical scheduler between frames.
            if(s_tvalid && !in_frame && !frame_busy && !s_tuser)
                marker_error<=1;    // non-SOF beat while idle
            if(take) begin
                if(s_tuser != !in_frame) marker_error<=1;
                if(s_tlast != (wx==in_w-12'd1)) marker_error<=1;
                in_x <= wx+1'b1;
                in_y <= wy;
                wbank <= wb;
                if(!in_frame) in_frame<=1;
                if(wx==in_w-12'd1) begin
                    in_x<=0;
                    if(wy==in_h-12'd1) begin
                        in_y<=in_h; in_frame<=0;
                    end else begin
                        in_y<=wy+1'b1;
                        wbank <= (wb==3'd6)?3'd0:wb+3'd1;
                    end
                end
            end

            // -------- vertical sweep --------
            lb_rd<=0;
            case(vstate)
            V_IDLE: begin
                vpend<=0;
                if(vs_can_start) begin
                    vstate<=V_RUN; vx<=1;
                    vph<=cy[15:10];
                    vsel<={mod7(clamp_max(Ly+16'sd5,in_h-12'd1)),
                           mod7(clamp_max(Ly+16'sd4,in_h-12'd1)),
                           mod7(clamp_max(Ly+16'sd3,in_h-12'd1)),
                           mod7(clamp_max(Ly+16'sd2,in_h-12'd1)),
                           mod7(clamp_max(Ly+16'sd1,in_h-12'd1)),
                           mod7(clamp_max(Ly+16'sd0,in_h-12'd1))};
                    lb_rd<=1; lb_addr<=0;
                end
            end
            V_RUN: begin
                if(vx<in_w) begin
                    lb_rd<=1; lb_addr<=vx[AW-1:0]; vx<=vx+1'b1;
                end
                vpend<=lb_rd;
                vwx<={{(12-AW){1'b0}}, lb_addr};
                if(vpend) begin
                    if(vp) ib1[vwx[AW-1:0]]<=vres;
                    else ib0[vwx[AW-1:0]]<=vres;
                    if(vwx==in_w-12'd1) begin
                        vstate<=V_IDLE; ibuf_full[vp]<=1; vp<=~vp;
                        oy<=oy+1'b1; cy<=cy+$signed({1'b0,sy_fp});
                    end
                end
            end
            endcase

            // -------- horizontal stage --------
            if(ib_rd) ibq <= hp ? ib1[ib_raddr] : ib0[ib_raddr];
            ib_rd<=0;
            case(hstate)
            H_IDLE: begin
                h_pend<=0;
                if(ibuf_full[hp] && !obuf_full[hop] && frame_busy) begin
                    hstate<=H_RUN; ox<=0; cx<=cx0;
                    h_ld<=(cx0>>>16)-16'sd2;
                    h_sv<=(cx0>>>16)-16'sd2;
                end
            end
            H_RUN: begin
                if(h_issue) begin
                    ib_rd<=1;
                    ib_raddr<=clamp_max(h_ld, in_w-12'd1);
                    h_ld<=h_ld+1'b1;
                end
                h_pend<=ib_rd;
                if(h_pend) begin
                    for(hw=0;hw<5;hw=hw+1) hwin[hw]<=hwin[hw+1];
                    hwin[5]<=ibq;
                    h_sv<=h_sv+1'b1;
                end
                if(h_can_emit) begin
                    if(hop) ob1[ox[AW-1:0]]<=hres;
                    else ob0[ox[AW-1:0]]<=hres;
                    ox<=ox+1'b1; cx<=cx+$signed({1'b0,sx_fp});
                    if(ox==out_w-12'd1) begin
                        hstate<=H_IDLE; obuf_full[hop]<=1; hop<=~hop;
                        ibuf_full[hp]<=0; hp<=~hp; h_pend<=0;
                    end
                end
            end
            endcase

            // -------- output drain --------
            case(dstate)
            D_IDLE: begin
                if(obuf_full[dp] && frame_busy) begin
                    dstate<=D_ROW; dx<=0; dsent<=0;
                end
            end
            D_ROW: begin
                if(d_fetch) begin
                    m_tdata <= dp ? ob1[dx[AW-1:0]] : ob0[dx[AW-1:0]];
                    m_tuser <= d_sof; m_tlast <= (dx==out_w-12'd1);
                    m_tvalid<=1; d_sof<=0; dx<=dx+1'b1;
                end else if(m_tvalid && m_tready) m_tvalid<=0;
                if(m_tvalid && m_tready) begin
                    dsent<=dsent+1'b1;
                    if(dsent==out_w-12'd1) begin
                        obuf_full[dp]<=0; dp<=~dp; drow<=drow+1'b1;
                        dstate<=D_IDLE;
                    end
                end
            end
            endcase
        end
    end

    `include "scale_lanczos3.vh"

    initial begin
        if(MAX_W<8) $fatal(1,"MAX_W too small");
    end
endmodule
