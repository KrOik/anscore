// ============================================================================
// cnn_engine.v - INT8 CNN inference engine for cores/acceleration/cnn_inference
//
// Network (fixed, see SPEC.md / host/cnn138k/cnn_model.py):
//   img 28x28x1 u8 -> conv1 3x3 s1 p1 1->16 acc32+bias
//      relu>>S1 clamp127, maxpool2x2 -> 14x14x16 (fmap_a, pos-major words)
//   conv2 3x3 s1 p1 16->16 acc32+bias
//      relu>>S2 clamp127, maxpool2x2 -> 7x7x16  (fmap_b)
//   fc 784->10 int32 scores (input order pos*16+ch)
//   digest = CRC32-IEEE over fmap_a + fmap_b + scores(LE), write order.
//
// Architecture per layer pass (input channel ic):
//   - stage the ic plane into plane_buf (sync reads of img_ram / fmap_a)
//   - stream a (H+1)x(W+2) virtual grid through a 2-line buffer + 3x3
//     window shift register; one valid window per output position
//   - 16 lanes x 9 int8 MACs combinationally per valid position
//   - acc RAM 1024x512b, pipelined RMW (positions distinct, no hazard);
//     ic==0 writes bias+dot (acc preload)
//   - pool/readout: 4 sequential acc reads per pooled position, quantize
//     + running max per lane, one 128b fmap write + 16-byte CRC step
//   - fc: unpack fmap_b into plane_buf, then per group g load the 10 lane
//     weight words (sync wmem reads) and MAC 9 bytes/group into scores
//
// Memories are synchronous-read reg arrays (BRAM friendly) everywhere
// except small scratch arrays (plane_buf, line buffers, bias_mem) and the
// host read port, which uses the spec'd 1-cycle registered-read contract.
// ============================================================================

module cnn_engine #(
    // Paths relative to repo root (sim + scripts run from D:\sipeedTANG20K).
    parameter IMG_FILE  = "cores/acceleration/cnn_inference/mem/img.mem",
    parameter WMEM_FILE = "cores/acceleration/cnn_inference/mem/wmem.mem",
    parameter BIAS_FILE = "cores/acceleration/cnn_inference/mem/bias.mem"
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         busy,
    output reg         done,
    output reg         err,
    input  wire        in_we,
    input  wire [9:0]  in_waddr,
    input  wire [7:0]  in_wdata,
    input  wire [1:0]  rd_sel,      // 0 scores,1 fmap_a,2 fmap_b,3 img
    input  wire [11:0] rd_addr,     // scores 0..9; fmap/img byte address
    output reg  [31:0] rd_data,
    output wire [31:0] digest,
    output wire [31:0] cycles
);

localparam integer S1 = 7;   // conv1 requant shift
localparam integer S2 = 7;   // conv2 requant shift (golden.json s2=7)

localparam [3:0] ST_IDLE   = 4'd0,
                 ST_STAGE  = 4'd1,   // fill plane_buf for current layer/ic
                 ST_WLOAD  = 4'd2,   // load 16 lane weight words for this ic
                 ST_SINIT  = 4'd3,   // clear window / line buffers / counters
                 ST_STREAM = 4'd4,   // stream virtual grid, MAC + acc RMW
                 ST_DRAIN  = 4'd5,   // flush acc RMW pipeline
                 ST_POOL   = 4'd6,   // quantize + 2x2 maxpool + fmap write + crc
                 ST_FCSTG  = 4'd7,   // unpack fmap_b words into plane_buf bytes
                 ST_FCW    = 4'd8,   // load 10 lane weight words for fc group
                 ST_FCMAC  = 4'd9,   // 9 fc MAC cycles for the group
                 ST_CRC    = 4'd10,  // fold 10 score words into CRC
                 ST_FIN    = 4'd11;

// ---------------------------------------------------------------- memories
reg  [7:0]   img_ram   [0:1023];   // input image (UART / readmemh)
reg  [7:0]   plane_buf [0:1023];   // staged ic plane / fc input vector
reg  [7:0]   lb0       [0:31];     // line buffer row cy-1
reg  [7:0]   lb1       [0:31];     // line buffer row cy-2
reg  [7:0]   win       [0:8];      // 3x3 window, tap k = ky*3+kx
reg  [71:0]  wmem      [0:2047];   // unified weights, addr L*128+w
reg  [71:0]  wmem_q;
reg  [31:0]  bias_mem  [0:41];     // 16 conv1 + 16 conv2 + 10 fc
reg  [71:0]  wreg      [0:15];     // per-lane active weight word
reg  [511:0] acc_mem   [0:1023];   // 16 x int32 per position
reg  [511:0] acc_q;
reg  [127:0] fmap_a    [0:255];    // conv1 pooled out (196 words used)
reg  [127:0] fmap_b    [0:63];     // conv2 pooled out (49 words used)
reg signed [31:0] score [0:9];   // signed so fc MAC context stays signed
reg  [7:0]   img_q;                // sync read data regs
reg  [127:0] fa_q;
reg  [7:0]   stp_q;                // plane_buf prefetch register
reg  [127:0] fb_w0, fb_w1;         // fc input word pair (prefetched in ST_FCW)
reg  [5:0]   fcw0;                 // word index of fb_w0 within fmap_b

// ---------------------------------------------------------------- state
reg  [3:0]   state;
reg          layer;                // 0 = conv1 (28x28), 1 = conv2 (14x14)
reg  [4:0]   ic;
reg  [10:0]  st_i;                 // staging counter
reg  [4:0]   wcnt;                 // weight load counter
reg  [4:0]   sy, sx;               // stream counters (virtual grid)
reg          s1_valid;
reg  [9:0]   s1_pos;
reg          s2_valid, s2_first;
reg  [9:0]   s2_pos;
reg signed [31:0] s2_dot [0:15];
reg  [2:0]   drain_cnt;
reg  [2:0]   ph;                   // pool phase 0..4
reg  [4:0]   ppy, ppx;             // pooled output coords
reg  [127:0] maxv;                 // running pooled max (16 bytes)
reg  [6:0]   fg;                   // fc group 0..87
reg  [3:0]   fj;                   // fc byte-in-group 0..8
reg  [3:0]   cc;                   // crc score counter
reg  [31:0]  crc;
reg  [31:0]  cyc;
reg          eng_half   = 1'b0;    // half-rate clock enable (timing margin)
reg          start_seen = 1'b0;    // full-rate start capture

// the 144-MAC dot-product path needs ~2 clock periods on this device
// (measured: run-to-run result variance at 50 MHz). Gate all datapath
// always-blocks with eng_half so the engine steps every other clock;
// the host read port, image write port and start capture stay full-rate.
always @(posedge clk) begin
    eng_half <= ~eng_half;
    if (!rst_n)                                       start_seen <= 1'b0;
    else if (start)                                   start_seen <= 1'b1;
    else if (eng_half && state == ST_IDLE && start_seen)
                                                      start_seen <= 1'b0;
end

// temporaries (blocking-assigned inside clocked block)
integer i, L, k, l;
reg signed [31:0] dotv;
reg  [71:0]  wv;
reg  [127:0] mrg, fw;
reg  [511:0] acc_wd;
reg  [7:0]   qtmp, fc_x;

// ---------------------------------------------------------------- params
wire [4:0]  curw   = layer ? 5'd14 : 5'd28;   // plane width/height
wire [4:0]  curh   = layer ? 5'd14 : 5'd28;
wire [4:0]  cin    = layer ? 5'd16 : 5'd1;    // input channels this layer
wire [10:0] nstg   = layer ? 11'd196 : 11'd784;
wire [10:0] wsel   = layer ? ({6'd0, ic} + 11'd1) : 11'd0;  // wmem word sel
wire [5:0]  bias_base = layer ? 6'd16 : 6'd0;
wire [3:0]  sh     = layer ? S2 : S1;
wire [4:0]  pw     = curw >> 1;               // pooled width 14 or 7
wire [8:0]  npool  = layer ? 9'd49 : 9'd196;

// stream step combinational decode (virtual grid (H+1) x (W+2))
wire        stp_valid = (sy >= 5'd1) && (sx >= 5'd2);
wire [9:0]  stp_pos   = (sy - 5'd1) * curw + (sx - 5'd2);

// next-step indices for the plane_buf prefetch (sync read, 1-cycle latency):
// stp_q always holds the byte for the CURRENT (sy,sx) step, fetched last cycle.
wire        sx_last   = (sx == curw + 5'd1);
wire [4:0]  sx_n      = sx_last ? 5'd0 : sx + 5'd1;
wire [4:0]  sy_n      = sx_last ? ((sy == curh) ? sy : sy + 5'd1) : sy;
wire [9:0]  nxt_idx   = (sx_n >= 5'd1) ? (sy_n * curw + sx_n - 5'd1) : 10'd0;
wire        stp_guard = (sy < curh && sx >= 5'd1 && sx <= curw);
wire [7:0]  stp_in    = stp_guard ? stp_q : 8'd0;

// pool source address: taps (dy,dx) = (ph[1],ph[0])
wire [9:0]  pool_src  = (ppy * 2 + {4'd0, ph[1]}) * curw
                      + (ppx * 2 + {4'd0, ph[0]});
wire [9:0]  ppidx     = ppy * pw + ppx;

// acc read port mux
wire        acc_re    = ((state == ST_STREAM) || (state == ST_DRAIN)) ?
                          s1_valid :
                        (state == ST_POOL) ? (ph <= 3'd3) : 1'b0;
wire [9:0]  acc_raddr = (state == ST_POOL) ? pool_src : s1_pos;

// fc input index and guarded byte
wire [9:0]  fc_i      = fg * 9 + {6'd0, fj};

assign digest = crc ^ 32'hFFFFFFFF;
assign cycles = cyc;

// ---------------------------------------------------------------- CRC funcs
function [31:0] crc32_b;
    input [31:0] crc_i;
    input [7:0]  b;
    integer n;
    reg [31:0] c;
    begin
        c = crc_i ^ {24'b0, b};
        for (n = 0; n < 8; n = n + 1)
            c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
        crc32_b = c;
    end
endfunction

function [31:0] crc16w;      // 16 bytes, lane 0 first (channel order)
    input [31:0]  crc_i;
    input [127:0] w;
    integer n;
    reg [31:0] c;
    begin
        c = crc_i;
        for (n = 0; n < 16; n = n + 1)
            c = crc32_b(c, w[8*n +: 8]);
        crc16w = c;
    end
endfunction

function [31:0] crc4w;       // one int32 score, little-endian
    input [31:0] crc_i;
    input [31:0] w;
    reg [31:0] c;
    begin
        c = crc32_b(crc_i, w[7:0]);
        c = crc32_b(c, w[15:8]);
        c = crc32_b(c, w[23:16]);
        c = crc32_b(c, w[31:24]);
        crc4w = c;
    end
endfunction

function [7:0] quant;        // relu >> sh clamp 127
    input signed [31:0] a;
    input [3:0]  shv;
    reg [31:0] t;
    begin
        if (a < 0) t = 32'd0;
        else       t = a >>> shv;
        quant = (t > 32'd127) ? 8'd127 : t[7:0];
    end
endfunction

// ---------------------------------------------------------------- init
initial begin
    $readmemh(IMG_FILE,  img_ram);
    $readmemh(WMEM_FILE, wmem);
    $readmemh(BIAS_FILE, bias_mem);
end

// ---------------------------------------------------------------- img write
always @(posedge clk) begin
    if (in_we && !busy)
        img_ram[in_waddr] <= in_wdata;
end

// ---------------------------------------------------------------- acc read
reg [511:0] acc_r1;
reg         acc_re_d;
always @(posedge clk) begin
    acc_re_d <= acc_re && eng_half;
    if (acc_re && eng_half)
        acc_r1 <= acc_mem[acc_raddr];
    if (acc_re_d)
        acc_q <= acc_r1;
end

// ---------------------------------------------------------------- host read
// Contract: rd_data valid the cycle after rd_sel/rd_addr (registered read).
always @(posedge clk) begin
    case (rd_sel)
        2'd0: rd_data <= (rd_addr < 12'd10) ? score[rd_addr[3:0]] : 32'd0;
        2'd1: begin
            fw = fmap_a[rd_addr[11:4]];
            rd_data <= {24'd0, fw[8*rd_addr[3:0] +: 8]};
        end
        2'd2: begin
            fw = fmap_b[rd_addr[9:4]];
            rd_data <= {24'd0, fw[8*rd_addr[3:0] +: 8]};
        end
        default: rd_data <= {24'd0, img_ram[rd_addr[9:0]]};
    endcase
end

// ---------------------------------------------------------------- main FSM
always @(posedge clk) begin
    if (!rst_n) begin
        state     <= ST_IDLE;
        busy      <= 1'b0;
        done      <= 1'b0;
        err       <= 1'b0;
        cyc       <= 32'd0;
        crc       <= 32'd0;
        layer     <= 1'b0;
        ic        <= 5'd0;
        st_i      <= 11'd0;
        wcnt      <= 5'd0;
        sy        <= 5'd0;
        sx        <= 5'd0;
        s1_valid  <= 1'b0;
        s2_valid  <= 1'b0;
        drain_cnt <= 3'd0;
        ph        <= 3'd0;
        ppy       <= 5'd0;
        ppx       <= 5'd0;
        fg        <= 7'd0;
        fj        <= 4'd0;
        cc        <= 4'd0;
    end else if (eng_half) begin
        // cycle counter: start -> done
        if (busy) cyc <= cyc + 32'd1;

        // ---- stream pipeline stage 1 (valid/pos capture) -----------------
        s1_valid <= (state == ST_STREAM) && stp_valid;
        s1_pos   <= stp_pos;

        // ---- stream pipeline stage 2 (dot product + acc RMW) -------------
        // win[] holds the window of the step captured in stage 1.
        s2_valid <= s1_valid;
        s2_pos   <= s1_pos;
        s2_first <= (ic == 5'd0);
        for (L = 0; L < 16; L = L + 1) begin
            wv   = wreg[L];
            dotv = 32'd0;
            for (k = 0; k < 9; k = k + 1)
                dotv = dotv + $signed({1'b0, win[k]}) *
                              $signed(wv[8*k +: 8]);
            s2_dot[L] <= dotv;
        end
        if (s2_valid) begin
            for (L = 0; L < 16; L = L + 1) begin
                if (s2_first)
                    acc_wd[32*L +: 32] =
                        $signed(bias_mem[bias_base + L]) + s2_dot[L];
                else
                    acc_wd[32*L +: 32] =
                        $signed(acc_q[32*L +: 32]) + s2_dot[L];
            end
            acc_mem[s2_pos] <= acc_wd;
        end

        // ---- FSM ----------------------------------------------------------
        case (state)

        ST_IDLE: begin
            if (start_seen) begin
                busy  <= 1'b1;
                done  <= 1'b0;
                err   <= 1'b0;
                cyc   <= 32'd0;
                crc   <= 32'hFFFFFFFF;
                layer <= 1'b0;
                ic    <= 5'd0;
                st_i  <= 11'd0;
                state <= ST_STAGE;
            end
        end

        // stage ic-plane (or image) into plane_buf via sync reads
        ST_STAGE: begin
            if (st_i < nstg) begin
                if (layer == 1'b0) img_q <= img_ram[st_i];
                else               fa_q  <= fmap_a[st_i];
            end
            if (st_i >= 11'd1) begin
                if (layer == 1'b0) plane_buf[st_i - 11'd1] <= img_q;
                else               plane_buf[st_i - 11'd1] <= fa_q[8*ic +: 8];
            end
            if (st_i == nstg) begin
                wcnt  <= 5'd0;
                state <= ST_WLOAD;
            end else begin
                st_i <= st_i + 11'd1;
            end
        end

        // load the 16 lane weight words for this ic (wmem addr L*128+wsel)
        ST_WLOAD: begin
            if (wcnt < 5'd16)
                wmem_q <= wmem[wcnt * 128 + wsel];
            if (wcnt >= 5'd1)
                wreg[wcnt - 5'd1] <= wmem_q;
            if (wcnt == 5'd16) begin
                wcnt  <= 5'd0;
                state <= ST_SINIT;
            end else begin
                wcnt <= wcnt + 5'd1;
            end
        end

        // clear window / line buffers / stream counters; prefetch first byte
        ST_SINIT: begin
            for (i = 0; i < 9; i = i + 1)
                win[i] <= 8'd0;
            for (i = 0; i < 32; i = i + 1) begin
                lb0[i] <= 8'd0;
                lb1[i] <= 8'd0;
            end
            sy    <= 5'd0;
            sx    <= 5'd0;
            stp_q <= plane_buf[10'd0];   // sync prefetch for step (0,0)
            state <= ST_STREAM;
        end

        // stream one virtual-grid step per cycle
        ST_STREAM: begin
            // shift 3x3 window left, push new right column
            win[0] <= win[1]; win[1] <= win[2]; win[2] <= lb1[sx];
            win[3] <= win[4]; win[4] <= win[5]; win[5] <= lb0[sx];
            win[6] <= win[7]; win[7] <= win[8]; win[8] <= stp_in;
            lb1[sx] <= lb0[sx];
            lb0[sx] <= stp_in;
            stp_q  <= plane_buf[nxt_idx];   // prefetch byte for next step
            if (sx == curw + 5'd1) begin
                sx <= 5'd0;
                if (sy == curh) begin
                    drain_cnt <= 3'd0;
                    state     <= ST_DRAIN;
                end else begin
                    sy <= sy + 5'd1;
                end
            end else begin
                sx <= sx + 5'd1;
            end
        end

        // let the last positions flush through the acc RMW pipeline
        ST_DRAIN: begin
            if (drain_cnt == 3'd3) begin
                if (ic == cin - 5'd1) begin
                    ph    <= 3'd0;
                    ppy   <= 5'd0;
                    ppx   <= 5'd0;
                    maxv  <= 128'd0;
                    state <= ST_POOL;
                end else begin
                    ic    <= ic + 5'd1;
                    st_i  <= 11'd0;
                    state <= ST_STAGE;
                end
            end else begin
                drain_cnt <= drain_cnt + 3'd1;
            end
        end

        // quantize + 2x2 maxpool + fmap write + crc, 5 cycles / pooled pos
        ST_POOL: begin
            if (ph >= 3'd1) begin
                // acc_q holds tap (ph-1) data; merge into maxv
                for (L = 0; L < 16; L = L + 1) begin
                    qtmp = quant(acc_q[32*L +: 32], sh);
                    if (ph == 3'd1)
                        mrg[8*L +: 8] = qtmp;
                    else
                        mrg[8*L +: 8] = (qtmp > maxv[8*L +: 8]) ?
                                        qtmp : maxv[8*L +: 8];
                end
                if (ph == 3'd4) begin
                    if (layer == 1'b0) fmap_a[ppidx] <= mrg;
                    else               fmap_b[ppidx] <= mrg;
                    crc <= crc16w(crc, mrg);
                    ph  <= 3'd0;
                    if (ppidx == npool - 9'd1) begin
                        // layer finished
                        if (layer == 1'b0) begin
                            layer <= 1'b1;
                            ic    <= 5'd0;
                            st_i  <= 11'd0;
                            state <= ST_STAGE;
                        end else begin
                            fg    <= 7'd0;
                            fj    <= 4'd0;
                            state <= ST_FCSTG;
                        end
                    end else begin
                        if (ppx == pw - 5'd1) begin
                            ppx <= 5'd0;
                            ppy <= ppy + 5'd1;
                        end else begin
                            ppx <= ppx + 5'd1;
                        end
                    end
                end else begin
                    maxv <= mrg;
                    ph   <= ph + 3'd1;
                end
            end else begin
                ph <= ph + 1'b1;
            end
        end

        // init fc scores from bias, then start the weight-group loop
        ST_FCSTG: begin
            for (L = 0; L < 10; L = L + 1)
                score[L] <= bias_mem[6'd32 + L];
            wcnt  <= 5'd0;
            state <= ST_FCW;
        end

        // load 10 lane weight words for fc group g (wmem addr L*128+17+g);
        // also prefetch the (at most two) fmap_b words this group needs
        ST_FCW: begin
            if (wcnt < 5'd10)
                wmem_q <= wmem[wcnt * 128 + 11'd17 + {4'd0, fg}];
            if (wcnt >= 5'd1)
                wreg[wcnt - 5'd1] <= wmem_q;
            if (wcnt == 5'd0) begin
                fcw0  <= ({3'd0, fg} * 7'd9) >> 4;
                fb_w0 <= fmap_b[({3'd0, fg} * 7'd9) >> 4];
            end
            if (wcnt == 5'd1)
                fb_w1 <= fmap_b[(({3'd0, fg} * 7'd9) + 10'd8) >> 4];
            if (wcnt == 5'd10) begin
                wcnt  <= 5'd0;
                fj    <= 4'd0;
                state <= ST_FCMAC;
            end else begin
                wcnt <= wcnt + 5'd1;
            end
        end

        // 9 MAC cycles: x = fmap_b byte 9g+j (from prefetched word pair),
        // lanes 0..9 use wreg byte j
        ST_FCMAC: begin
            fc_x = (fc_i < 10'd784)
                 ? ((fc_i[9:4] == {4'd0, fcw0}) ? fb_w0[8*fc_i[3:0] +: 8]
                                               : fb_w1[8*fc_i[3:0] +: 8])
                 : 8'd0;
            for (L = 0; L < 10; L = L + 1) begin
                wv   = wreg[L];
                dotv = $signed({1'b0, fc_x}) * $signed(wv[8*fj +: 8]);
                score[L] <= score[L] + dotv;
            end
            if (fj == 4'd8) begin
                fj <= 4'd0;
                if (fg == 7'd87) begin
                    cc    <= 4'd0;
                    state <= ST_CRC;
                end else begin
                    fg    <= fg + 7'd1;
                    wcnt  <= 5'd0;
                    state <= ST_FCW;
                end
            end else begin
                fj <= fj + 4'd1;
            end
        end

        // fold 10 score words (little-endian) into the CRC
        ST_CRC: begin
            crc <= crc4w(crc, score[cc]);
            if (cc == 4'd9) begin
                state <= ST_FIN;
            end else begin
                cc <= cc + 4'd1;
            end
        end

        ST_FIN: begin
            busy  <= 1'b0;
            done  <= 1'b1;
            state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
        endcase
    end
end

endmodule
