// ============================================================================
// sig_selftest: unit selftest aggregator for sigproc_20k (GW2A-18C).
// Structure cloned from cores/acceleration/cnn_systolic/src/cnn_selftest.v.
//   ce = 1 clk in 16 (deep fnv/mul16 chains get ~590ns per logical beat)
//   DUTs run on .clk_en(ce || !rst_n)  (otsu_thresh runs full-rate: its
//   per-beat logic is a single add/compare, no deep chains)
//   per-unit FNV-1a digest vs EXP_* constants from tools/golden_model.py
//   verdict: pass_r === done_w (T6, X fails)
//
// Units:
//   U0 FFT : fft64, 4 vectors (impulse/const/tone-k4/alternating),
//            digest over |X[k]|^2 (re^2+im^2, 4B LE) x 256
//   U1 CIC : cic_dec8, 128-sample ramp, digest over 16 outputs (3B each)
//   U2 HST : hist256, phase A 512 back-to-back-pair samples + readout,
//            phase B 96 samples on dirty bins + readout + totals
//   U3 OTSU: otsu_thresh, 2 ROM histograms, digest over thr+score x 2
// ============================================================================
module sig_selftest #(
    parameter [3:0] UNIT_EN = 4'hF
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         all_done,
    output reg         all_pass,
    output reg         any_fail,
    input  wire [4:0]  digest_sel,
    output reg  [31:0] digest_q,
    output wire [3:0]  done_mask,
    output wire [3:0]  pass_mask
);

function [31:0] fnv;
    input [31:0] h;
    input [7:0]  b;
    reg [31:0] x;
    begin
        x = h ^ {24'd0, b};
        fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
    end
endfunction

// exact signed 16x16 -> 32 shift-add multiply (same as fft64.mul16)
function signed [31:0] mul16;
    input signed [15:0] a;
    input signed [15:0] b;
    reg signed [31:0] acc, sa;
    integer i;
    begin
        sa  = a;
        acc = 32'sd0;
        for (i = 0; i < 15; i = i + 1)
            if (b[i]) acc = acc + (sa <<< i);
        if (b[15]) acc = acc - (sa <<< 15);
        mul16 = acc;
    end
endfunction

// ---------------------------------------------------------------------------
// beat-rate clock enable
// ---------------------------------------------------------------------------
reg [3:0] ce_div = 4'd0;
wire ce = (ce_div == 4'd15);
always @(posedge clk) ce_div <= ce_div + 4'd1;

// ---------------------------------------------------------------------------
// Unit 0: fft64  (EXP from golden_model.py fft_digest)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_FFT = 32'h53d1ddaf;
localparam [3:0] F_LOAD = 4'd1;
localparam [3:0] F_START = 4'd2;
localparam [3:0] F_WBUSY = 4'd7;
localparam [3:0] F_WAIT = 4'd3;
localparam [3:0] F_RDQ  = 4'd4;
localparam [3:0] F_RDZ  = 4'd6;
localparam [3:0] F_RDC  = 4'd5;

reg signed [15:0] costab [0:31];
initial $readmemh("fft64_cos.mem", costab);

function signed [15:0] stim_fft;
    input [1:0] v;
    input [5:0] n;
    reg [5:0] ci;
    reg signed [15:0] c;
    begin
        case (v)
            2'd0: stim_fft = (n == 6'd0) ? 16'sd16384 : 16'sd0;
            2'd1: stim_fft = 16'sd4096;
            2'd2: begin
                ci = {n[3:0], 2'b00};            // (4n) mod 64
                c  = ci[5] ? -costab[ci[4:0]] : costab[ci[4:0]];
                stim_fft = c >>> 2;
            end
            default: stim_fft = n[0] ? -16'sd8192 : 16'sd8192;
        endcase
    end
endfunction

reg [3:0]  fstate;
reg [1:0]  fvec;
reg [7:0]  fcnt;
reg        f_done;
reg [31:0] f_dg = 32'h811c9dc5;
reg        fft_ld_en, fft_start, fft_rd_en;
reg [5:0]  fft_ld_addr, fft_rd_addr;
wire       fft_busy, fft_done;
wire signed [15:0] fft_rd_re, fft_rd_im;
wire [31:0] fft_mag2 = mul16(fft_rd_re, fft_rd_re) +
                      mul16(fft_rd_im, fft_rd_im);

generate
if (UNIT_EN[0]) begin : g_u0
fft64 u_fft (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .ld_en(fft_ld_en), .ld_addr(fft_ld_addr),
    .ld_re(stim_fft(fvec, fft_ld_addr)), .ld_im(16'sd0),
    .start(fft_start), .busy(fft_busy), .done(fft_done),
    .rd_en(fft_rd_en), .rd_addr(fft_rd_addr),
    .rd_re(fft_rd_re), .rd_im(fft_rd_im)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fstate <= F_LOAD; fvec <= 2'd0; fcnt <= 8'd0;
        f_done <= 1'b0; f_dg <= 32'h811c9dc5;
        fft_ld_en <= 1'b0; fft_start <= 1'b0; fft_rd_en <= 1'b0;
        fft_ld_addr <= 6'd0; fft_rd_addr <= 6'd0;
    end else if (ce && !f_done) begin
        fft_ld_en <= 1'b0; fft_start <= 1'b0; fft_rd_en <= 1'b0;
        case (fstate)
            F_LOAD: begin
                fft_ld_en <= 1'b1;
                fft_ld_addr <= fcnt[5:0];
                if (fcnt == 8'd63) begin
                    fcnt <= 8'd0; fstate <= F_START;
                end else begin
                    fcnt <= fcnt + 8'd1;
                end
            end
            F_START: begin
                fft_start <= 1'b1;
                fstate <= F_WBUSY;          // start consumed during F_WBUSY
            end
            F_WBUSY: begin
                if (fft_busy) fstate <= F_WAIT;  // done low now, safe to poll
            end
            F_WAIT: begin
                if (fft_done) begin
                    fcnt <= 8'd0; fstate <= F_RDQ;
                end
            end
            F_RDQ: begin
                fft_rd_en <= 1'b1;
                fft_rd_addr <= fcnt[5:0];
                fstate <= F_RDZ;            // rd_en/addr live during F_RDZ
            end
            F_RDZ: begin
                fstate <= F_RDC;            // q <= mem[addr] at end of F_RDZ
            end
            F_RDC: begin
                f_dg <= fnv(fnv(fnv(fnv(f_dg, fft_mag2[7:0]),
                            fft_mag2[15:8]), fft_mag2[23:16]), fft_mag2[31:24]);
                if (fcnt == 8'd63) begin
                    fcnt <= 8'd0;
                    if (fvec == 2'd3) begin
                        f_done <= 1'b1;
                    end else begin
                        fvec <= fvec + 2'd1;
                        fstate <= F_LOAD;
                    end
                end else begin
                    fcnt <= fcnt + 8'd1;
                    fstate <= F_RDQ;
                end
            end
            default: fstate <= F_LOAD;
        endcase
    end
end
end else begin : g_u0_off
    always @(posedge clk) f_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 1: cic_dec8  (EXP from golden_model.py cic_digest)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_CIC = 32'h076987e4;
reg [7:0]  cic_i;
reg        cic_done;
reg [31:0] cic_dg = 32'h811c9dc5;
wire [15:0] cic_s3 = {13'd0, (cic_i[7:3])};
wire [15:0] cic_s7 = cic_s3 + (cic_s3 << 1) + (cic_s3 << 2);
wire signed [15:0] cic_st = $signed({8'd0, cic_i}) +
                            $signed({6'd0, cic_i, 2'b00}) +
                            $signed(cic_s7) - 16'sd100;
wire signed [7:0] cic_din = cic_st[7:0];
wire cic_iv = (cic_i < 8'd128);
wire cic_ov;
wire signed [16:0] cic_dout;

generate
if (UNIT_EN[1]) begin : g_u1
cic_dec8 u_cic (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .in_valid(cic_iv), .din(cic_din),
    .out_valid(cic_ov), .dout(cic_dout)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cic_i <= 8'd0; cic_done <= 1'b0; cic_dg <= 32'h811c9dc5;
    end else if (ce && !cic_done) begin
        if (cic_i < 8'd140) cic_i <= cic_i + 8'd1;
        if (cic_ov) begin
            cic_dg <= fnv(fnv(fnv(cic_dg, cic_dout[7:0]),
                          cic_dout[15:8]), {7'd0, cic_dout[16]});
        end
        if (cic_i == 8'd139) cic_done <= 1'b1;
    end
end
end else begin : g_u1_off
    always @(posedge clk) cic_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 2: hist256  (EXP from golden_model.py hist_digest)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_HIST = 32'hc4b4f3d5;
localparam [4:0] H_CLR   = 5'd0;
localparam [4:0] H_CLRW  = 5'd1;
localparam [4:0] H_CLRW2 = 5'd14;
localparam [4:0] H_PA    = 5'd2;
localparam [4:0] H_DRN   = 5'd3;
localparam [4:0] H_RA    = 5'd4;
localparam [4:0] H_RAZ   = 5'd12;
localparam [4:0] H_RB    = 5'd5;
localparam [4:0] H_TA    = 5'd6;
localparam [4:0] H_PB    = 5'd7;
localparam [4:0] H_DRN2  = 5'd8;
localparam [4:0] H_RC    = 5'd9;
localparam [4:0] H_RCZ   = 5'd13;
localparam [4:0] H_RD    = 5'd10;
localparam [4:0] H_TB    = 5'd11;

reg [4:0]  hstate;
reg [9:0]  hcnt;
reg        h_done;
reg [31:0] h_dg = 32'h811c9dc5;
reg        hist_start, hist_iv, hist_rd_en;
reg [7:0]  hist_bin, hist_rd_addr;
wire       hist_busy;
wire [23:0] hist_total;
wire [15:0] hist_rd_data;

generate
if (UNIT_EN[2]) begin : g_u2
hist256 u_hist (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .start(hist_start), .busy(hist_busy),
    .in_valid(hist_iv), .bin(hist_bin), .total(hist_total),
    .rd_en(hist_rd_en), .rd_addr(hist_rd_addr), .rd_data(hist_rd_data)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hstate <= H_CLR; hcnt <= 10'd0;
        h_done <= 1'b0; h_dg <= 32'h811c9dc5;
        hist_start <= 1'b0; hist_iv <= 1'b0; hist_rd_en <= 1'b0;
        hist_bin <= 8'd0; hist_rd_addr <= 8'd0;
    end else if (ce && !h_done) begin
        hist_start <= 1'b0; hist_iv <= 1'b0; hist_rd_en <= 1'b0;
        case (hstate)
            H_CLR: begin
                hist_start <= 1'b1;
                hstate <= H_CLRW;
            end
            H_CLRW: begin
                if (hist_busy) hstate <= H_CLRW2;  // clearing acknowledged
            end
            H_CLRW2: begin
                if (!hist_busy) begin
                    hcnt <= 10'd0; hstate <= H_PA;
                end
            end
            H_PA: begin
                hist_iv <= 1'b1;
                hist_bin <= {1'b0, hcnt[8:1]};          // i>>1, pairs
                if (hcnt == 10'd511) begin
                    hcnt <= 10'd0; hstate <= H_DRN;
                end else begin
                    hcnt <= hcnt + 10'd1;
                end
            end
            H_DRN: begin
                if (hcnt == 10'd3) begin
                    hcnt <= 10'd0; hstate <= H_RA;
                end else begin
                    hcnt <= hcnt + 10'd1;
                end
            end
            H_RA: begin
                hist_rd_en <= 1'b1;
                hist_rd_addr <= hcnt[7:0];
                hstate <= H_RAZ;            // rd_en/addr live during H_RAZ
            end
            H_RAZ: begin
                hstate <= H_RB;             // q <= mem[addr] at end of H_RAZ
            end
            H_RB: begin
                h_dg <= fnv(fnv(h_dg, hist_rd_data[7:0]), hist_rd_data[15:8]);
                if (hcnt == 10'd255) hstate <= H_TA;
                else begin
                    hcnt <= hcnt + 10'd1; hstate <= H_RA;
                end
            end
            H_TA: begin
                h_dg <= fnv(fnv(fnv(h_dg, hist_total[7:0]),
                            hist_total[15:8]), hist_total[23:16]);
                hcnt <= 10'd0; hstate <= H_PB;
            end
            H_PB: begin
                hist_iv <= 1'b1;
                hist_bin <= (hcnt[7:0] + (hcnt[7:0] << 1)); // (3i)&0xFF
                if (hcnt == 10'd95) begin
                    hcnt <= 10'd0; hstate <= H_DRN2;
                end else begin
                    hcnt <= hcnt + 10'd1;
                end
            end
            H_DRN2: begin
                if (hcnt == 10'd3) begin
                    hcnt <= 10'd0; hstate <= H_RC;
                end else begin
                    hcnt <= hcnt + 10'd1;
                end
            end
            H_RC: begin
                hist_rd_en <= 1'b1;
                hist_rd_addr <= hcnt[7:0];
                hstate <= H_RCZ;
            end
            H_RCZ: begin
                hstate <= H_RD;
            end
            H_RD: begin
                h_dg <= fnv(fnv(h_dg, hist_rd_data[7:0]), hist_rd_data[15:8]);
                if (hcnt == 10'd255) hstate <= H_TB;
                else begin
                    hcnt <= hcnt + 10'd1; hstate <= H_RC;
                end
            end
            H_TB: begin
                h_dg <= fnv(fnv(fnv(h_dg, hist_total[7:0]),
                            hist_total[15:8]), hist_total[23:16]);
                h_done <= 1'b1;
            end
            default: hstate <= H_CLR;
        endcase
    end
end
end else begin : g_u2_off
    always @(posedge clk) h_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 3: otsu_thresh  (EXP from golden_model.py otsu_digest)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_OTSU = 32'hd97ce6d3;
localparam [1:0] O_ST = 2'd0;
localparam [1:0] O_WT = 2'd1;
localparam [1:0] O_FD = 2'd2;

reg [15:0] ohist [0:511];
initial $readmemh("otsu_hist.mem", ohist);

reg [1:0]  ostate;
reg        ovec;
reg        o_done;
reg [31:0] o_dg = 32'h811c9dc5;
reg        otsu_start;
wire       otsu_busy, otsu_done, otsu_hreq;
wire [7:0] otsu_haddr, otsu_thr;
wire [31:0] otsu_score;
wire [15:0] otsu_hdata = ohist[{ovec, otsu_haddr}];

generate
if (UNIT_EN[3]) begin : g_u3
otsu_thresh u_otsu (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n),   // full-rate: shallow logic
    .start(otsu_start), .busy(otsu_busy), .done(otsu_done),
    .h_req(otsu_hreq), .h_addr(otsu_haddr), .h_data(otsu_hdata),
    .thr(otsu_thr), .best_score(otsu_score)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ostate <= O_ST; ovec <= 1'b0;
        o_done <= 1'b0; o_dg <= 32'h811c9dc5;
        otsu_start <= 1'b0;
    end else if (ce && !o_done) begin
        otsu_start <= 1'b0;
        case (ostate)
            O_ST: begin
                otsu_start <= 1'b1;
                ostate <= O_WT;
            end
            O_WT: begin
                if (otsu_done) ostate <= O_FD;
            end
            O_FD: begin
                o_dg <= fnv(fnv(fnv(fnv(fnv(o_dg, otsu_thr),
                            otsu_score[7:0]), otsu_score[15:8]),
                            otsu_score[23:16]), otsu_score[31:24]);
                if (ovec) begin
                    o_done <= 1'b1;
                end else begin
                    ovec <= 1'b1; ostate <= O_ST;
                end
            end
            default: ostate <= O_ST;
        endcase
    end
end
end else begin : g_u3_off
    always @(posedge clk) o_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------
wire [3:0] done_w = {o_done, h_done, cic_done, f_done};
assign done_mask = done_w;

function [31:0] exp_digest;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: exp_digest = EXP_FFT;
            2'd1: exp_digest = EXP_CIC;
            2'd2: exp_digest = EXP_HIST;
            default: exp_digest = EXP_OTSU;
        endcase
    end
endfunction

reg [31:0] digests [0:3];
reg [3:0]  pass_r;
assign pass_mask = pass_r;

integer ui;
always @(posedge clk) begin
    digests[0] <= f_dg;   digests[1] <= cic_dg;
    digests[2] <= h_dg;   digests[3] <= o_dg;
    for (ui = 0; ui < 4; ui = ui + 1) begin
        pass_r[ui] <= done_w[ui] &&
                      (!UNIT_EN[ui] || digests[ui] == exp_digest(ui[1:0]));
    end
end

always @(*) begin
    digest_q = digests[digest_sel[1:0]];
end

reg verdict_settled;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        all_done <= 1'b0; all_pass <= 1'b0; any_fail <= 1'b0;
        verdict_settled <= 1'b0;
    end else if (ce && !all_done) begin
        if (&done_w) all_done <= 1'b1;        // X-safe: X makes if() false
    end else if (all_done && !verdict_settled) begin
        verdict_settled <= 1'b1;
        all_pass <= (pass_r === done_w);
        any_fail <= (pass_r !== done_w);
    end
end

endmodule
