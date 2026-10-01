// ============================================================================
// dsp_selftest.v -- unit selftest aggregator for dsp_20k (GW2A-18C bring-up).
// Mirrors cnn_selftest.v structure: ce = clk/16 logical beat, every DUT
// register gated by clk_en, per-unit FNV-1a digest vs golden EXP_* constants
// produced by the INDEPENDENT Python model (tools/golden_model.py).
//
// Units:
//   U0 CRDR cordic rotation  (64 angles, x=9949 -> cos/sin)
//   U1 CRDV cordic vectoring (48 (x,y) pairs -> mag + atan)
//   U2 DDS  dds_nco          (128 beats, sine + square bytes)
//   U3 FIR  fir16            (80 samples -> y bytes)
//   U4 PID  pid_core         (64 error steps -> u bytes)
// ============================================================================
module dsp_selftest #(
    parameter [15:0] UNIT_EN = 16'hFFFF
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         all_done,
    output reg         all_pass,
    output reg         any_fail,
    input  wire [4:0]  digest_sel,
    output reg  [31:0] digest_q,
    output wire [15:0] done_mask,
    output wire [15:0] pass_mask
);

function [31:0] fnv;
    input [31:0] h;
    input [7:0]  b;
    reg [31:0] x;
    begin
        x = h ^ {24'd0, b};
        // FNV-1a prime 0x01000193 as shift-add (bits 0,1,4,7,8,24)
        fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
    end
endfunction

reg [3:0] ce_div = 4'd0;
wire ce = (ce_div == 4'd15);
always @(posedge clk) ce_div <= ce_div + 4'd1;

// ---------------------------------------------------------------------------
// Unit 0: cordic rotation. z sweeps -31000..32000 (Q2.14 rad, |z|>pi/2 folds).
// x_in = 9949 = round(K*2^14) -> unit-amplitude cos/sin out.
// Digest: per out_valid -> x_out lo,hi, y_out lo,hi.
// ---------------------------------------------------------------------------
localparam [31:0] EXP_CRDR = 32'h5b8ccf9d;
reg [6:0]  cr_i = 7'd0;
reg        cr_done = 1'b0;
reg [6:0]  cr_got = 7'd0;
reg [31:0] cr_dg = 32'h811c9dc5;
wire signed [15:0] cr_xo, cr_yo;
wire signed [17:0] cr_zo;
wire cr_ov;
// z_in = -31000 + i*1000 (i*1000 = i<<10 - i<<5 + i<<3), 18-bit intermediate
wire signed [17:0] cr_zw = -18'sd31000 + ({11'd0, cr_i} << 10)
                           - ({11'd0, cr_i} << 5) + ({11'd0, cr_i} << 3);
wire signed [15:0] cr_zin = cr_zw[15:0];

generate
if (UNIT_EN[0]) begin : g_u0
cordic u_crdr (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .mode(1'b0), .in_valid(cr_i < 7'd64),
    .x_in(16'sd9949), .y_in(16'sd0), .z_in(cr_zin),
    .x_out(cr_xo), .y_out(cr_yo), .z_out(cr_zo), .out_valid(cr_ov)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cr_i <= 7'd0; cr_done <= 1'b0; cr_got <= 7'd0; cr_dg <= 32'h811c9dc5;
    end else if (ce && !cr_done) begin
        if (cr_i < 7'd100) cr_i <= cr_i + 7'd1;
        if (cr_ov) begin
            cr_got <= cr_got + 7'd1;
            cr_dg <= fnv(fnv(fnv(fnv(cr_dg, cr_xo[7:0]), cr_xo[15:8]),
                                 cr_yo[7:0]), cr_yo[15:8]);
        end
        if (cr_got == 7'd64 || cr_i == 7'd99) cr_done <= 1'b1;
    end
end
end else begin : g_u0_off
    always @(posedge clk) cr_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 1: cordic vectoring. 48 (x,y) pairs; x_raw/y_raw wrap counters keep
// the stimulus multiply-free and exercise x<0 pre-rotation.
// Digest: per out_valid -> x_out lo,hi, z_out lo,hi,{6'b0,z_out[17:16]}.
// ---------------------------------------------------------------------------
localparam [31:0] EXP_CRDV = 32'h4a4e2d09;
reg [6:0]  cv_i = 7'd0;
reg        cv_done = 1'b0;
reg [6:0]  cv_got = 7'd0;
reg [31:0] cv_dg = 32'h811c9dc5;
reg [14:0] cv_xraw = 15'd0;   // +=521 mod 30000 -> x_in = xraw-15000
reg [14:0] cv_yraw = 15'd0;   // +=733 mod 24000 -> y_in = yraw-12000
wire signed [15:0] cv_xo, cv_yo;
wire signed [17:0] cv_zo;
wire cv_ov;
wire signed [15:0] cv_xin = {1'b0, cv_xraw} - 16'sd15000;
wire signed [15:0] cv_yin = {1'b0, cv_yraw} - 16'sd12000;

generate
if (UNIT_EN[1]) begin : g_u1
cordic u_crdv (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .mode(1'b1), .in_valid(cv_i < 7'd48),
    .x_in(cv_xin), .y_in(cv_yin), .z_in(16'sd0),
    .x_out(cv_xo), .y_out(cv_yo), .z_out(cv_zo), .out_valid(cv_ov)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cv_i <= 7'd0; cv_done <= 1'b0; cv_got <= 7'd0; cv_dg <= 32'h811c9dc5;
        cv_xraw <= 15'd0; cv_yraw <= 15'd0;
    end else if (ce && !cv_done) begin
        if (cv_i < 7'd90) cv_i <= cv_i + 7'd1;
        if (cv_i < 7'd48) begin
            cv_xraw <= (cv_xraw >= 15'd29479) ? (cv_xraw + 15'd521 - 15'd30000)
                                              : (cv_xraw + 15'd521);
            cv_yraw <= (cv_yraw >= 15'd23267) ? (cv_yraw + 15'd733 - 15'd24000)
                                              : (cv_yraw + 15'd733);
        end
        if (cv_ov) begin
            cv_got <= cv_got + 7'd1;
            cv_dg <= fnv(fnv(fnv(fnv(fnv(cv_dg, cv_xo[7:0]), cv_xo[15:8]),
                                 cv_zo[7:0]), cv_zo[15:8]),
                             {6'd0, cv_zo[17:16]});
        end
        if (cv_got == 7'd48 || cv_i == 7'd89) cv_done <= 1'b1;
    end
end
end else begin : g_u1_off
    always @(posedge clk) cv_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 2: dds_nco. tw=0x08000000 (LUT address step 8/beat). Capture beats
// 2..129 (128 samples): sine lo,hi + {7'b0,square}.
// ---------------------------------------------------------------------------
localparam [31:0] EXP_DDS = 32'h0f185bed;
reg [7:0]  dds_i = 8'd0;
reg        dds_done = 1'b0;
reg [31:0] dds_dg = 32'h811c9dc5;
wire signed [15:0] dds_sine;
wire dds_sq;
wire [31:0] dds_phase;

generate
if (UNIT_EN[2]) begin : g_u2
dds_nco #(.LUT_FILE("sine256.mem")) u_dds (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .run(dds_i < 8'd130), .tuning_word(32'h08000000),
    .sine_out(dds_sine), .square_out(dds_sq), .phase_out(dds_phase)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dds_i <= 8'd0; dds_done <= 1'b0; dds_dg <= 32'h811c9dc5;
    end else if (ce && !dds_done) begin
        if (dds_i < 8'd140) dds_i <= dds_i + 8'd1;
        if (dds_i >= 8'd2 && dds_i < 8'd130) begin
            dds_dg <= fnv(fnv(fnv(dds_dg, dds_sine[7:0]), dds_sine[15:8]),
                              {7'd0, dds_sq});
        end
        if (dds_i == 8'd130) dds_done <= 1'b1;
    end
end
end else begin : g_u2_off
    always @(posedge clk) dds_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 3: fir16. 80 samples; first 8 are a step to 200 (exercise saturation),
// then (i*53+7)&0xFF. Digest: y_out byte per out_valid.
// ---------------------------------------------------------------------------
localparam [31:0] EXP_FIR = 32'h20038c18;
reg [6:0]  f_i = 7'd0;
reg        f_done = 1'b0;
reg [6:0]  f_got = 7'd0;
reg [31:0] f_dg = 32'h811c9dc5;
wire [7:0] f_y;
wire f_ov;
// (i*53+7) mod 256 -- 8-bit arithmetic wraps automatically
wire [7:0] f_samp = (f_i < 7'd8) ? 8'd200 :
                    ({1'b0, f_i} + ({1'b0, f_i} << 2) + ({1'b0, f_i} << 4)
                   + ({1'b0, f_i} << 5) + 8'd7);

generate
if (UNIT_EN[3]) begin : g_u3
fir16 u_fir (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .in_valid(f_i < 7'd80), .sample_in(f_samp),
    .y_out(f_y), .out_valid(f_ov)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        f_i <= 7'd0; f_done <= 1'b0; f_got <= 7'd0; f_dg <= 32'h811c9dc5;
    end else if (ce && !f_done) begin
        if (f_i < 7'd110) f_i <= f_i + 7'd1;
        if (f_ov) begin
            f_got <= f_got + 7'd1;
            f_dg <= fnv(f_dg, f_y);
        end
        if (f_got == 7'd80 || f_i == 7'd109) f_done <= 1'b1;
    end
end
end else begin : g_u3_off
    always @(posedge clk) f_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 4: pid_core. 64 error beats: +4000 x16, -2000 x16, then
// ((i*997)&0x3FFF)-4000 (bi-polar, exercises clamps). Digest: u_out lo,hi.
// ---------------------------------------------------------------------------
localparam [31:0] EXP_PID = 32'h5c690862;
reg [6:0]  p_i = 7'd0;
reg        p_done = 1'b0;
reg [6:0]  p_got = 7'd0;
reg [31:0] p_dg = 32'h811c9dc5;
wire signed [15:0] p_u;
wire p_ov;
// i*997 in 16-bit (shift-add), truncated to low 14 bits == mod 16384
wire [15:0] p_prod = {9'd0, p_i} + ({9'd0, p_i} << 2) + ({9'd0, p_i} << 5)
                   + ({9'd0, p_i} << 6) + ({9'd0, p_i} << 7)
                   + ({9'd0, p_i} << 8) + ({9'd0, p_i} << 9);
wire [13:0] p_raw = p_prod[13:0];
wire signed [15:0] p_err = (p_i < 7'd16) ? 16'sd4000 :
                           (p_i < 7'd32) ? -16'sd2000 :
                           ({2'b00, p_raw} - 16'sd4000);

generate
if (UNIT_EN[4]) begin : g_u4
pid_core u_pid (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .in_valid(p_i < 7'd64), .err_in(p_err),
    .u_out(p_u), .out_valid(p_ov)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p_i <= 7'd0; p_done <= 1'b0; p_got <= 7'd0; p_dg <= 32'h811c9dc5;
    end else if (ce && !p_done) begin
        if (p_i < 7'd90) p_i <= p_i + 7'd1;
        if (p_ov) begin
            p_got <= p_got + 7'd1;
            p_dg <= fnv(fnv(p_dg, p_u[7:0]), p_u[15:8]);
        end
        if (p_got == 7'd64 || p_i == 7'd89) p_done <= 1'b1;
    end
end
end else begin : g_u4_off
    always @(posedge clk) p_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------
wire [15:0] done_w = {11'd0, p_done, f_done, dds_done, cv_done, cr_done};
assign done_mask = done_w;

function [31:0] exp_digest;
    input [3:0] idx;
    begin
        case (idx)
            4'd0: exp_digest = EXP_CRDR;
            4'd1: exp_digest = EXP_CRDV;
            4'd2: exp_digest = EXP_DDS;
            4'd3: exp_digest = EXP_FIR;
            4'd4: exp_digest = EXP_PID;
            default: exp_digest = 32'd0;
        endcase
    end
endfunction

reg [31:0] digests [0:15];
reg [15:0] pass_r;
assign pass_mask = pass_r;

integer ui;
always @(posedge clk) begin
    digests[0] <= cr_dg;  digests[1] <= cv_dg;  digests[2] <= dds_dg;
    digests[3] <= f_dg;   digests[4] <= p_dg;
    for (ui = 5; ui < 16; ui = ui + 1) digests[ui] <= 32'h811c9dc5;
    for (ui = 0; ui < 16; ui = ui + 1) begin
        pass_r[ui] <= done_w[ui] &&
                      (!UNIT_EN[ui] || digests[ui] == exp_digest(ui[3:0]));
    end
end

always @(*) begin
    digest_q = digests[digest_sel[3:0]];
end

reg verdict_settled;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        all_done <= 1'b0; all_pass <= 1'b0; any_fail <= 1'b0;
        verdict_settled <= 1'b0;
    end else if (ce && !all_done) begin
        all_done <= &done_w[4:0];   // bits 15:5 are hardwired 0 (5 units)
    end else if (!verdict_settled) begin
        verdict_settled <= 1'b1;
        all_pass <= (pass_r === done_w);
        any_fail <= (pass_r !== done_w);
    end
end

endmodule
