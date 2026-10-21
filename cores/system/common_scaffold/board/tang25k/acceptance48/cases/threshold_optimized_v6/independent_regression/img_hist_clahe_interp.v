// Production integration wrapper. The numerical implementation is the
// five-stage elastic pipeline in img_hist_clahe_interp_pipe5.v.
module img_hist_clahe_interp #(
    parameter integer FRACTION_BITS = 8,
    parameter integer TAG_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_lut00,
    input wire [7:0] s_lut10,
    input wire [7:0] s_lut01,
    input wire [7:0] s_lut11,
    input wire [FRACTION_BITS:0] s_fx,
    input wire [FRACTION_BITS:0] s_fy,
    input wire s_sof,
    input wire s_eol,
    input wire [TAG_WIDTH-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire [7:0] m_gray,
    output wire m_sof,
    output wire m_eol,
    output wire [TAG_WIDTH-1:0] m_tag,
    output wire m_error
);
    img_hist_clahe_interp_pipe5 #(
        .FRACTION_BITS(FRACTION_BITS),
        .TAG_WIDTH(TAG_WIDTH)
    ) implementation (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_lut00(s_lut00), .s_lut10(s_lut10),
        .s_lut01(s_lut01), .s_lut11(s_lut11),
        .s_fx(s_fx), .s_fy(s_fy), .s_sof(s_sof), .s_eol(s_eol),
        .s_tag(s_tag), .m_valid(m_valid), .m_ready(m_ready),
        .m_gray(m_gray), .m_sof(m_sof), .m_eol(m_eol),
        .m_tag(m_tag), .m_error(m_error)
    );
endmodule

// Five-stage elastic bilinear interpolation pipeline for the four CLAHE LUT
// entries associated with one source pixel. Tile selection and LUT access are
// external. fx/fy are unsigned Q0.FRACTION_BITS values with an endpoint bit;
// legal coordinates are in [0, 2**FRACTION_BITS].
//
// Arithmetic is deliberately not rounded between stages. Only the last stage
// performs round-half-up, fixed-point shifting, and output saturation.
module img_hist_clahe_interp_pipe5 #(
    parameter integer FRACTION_BITS = 8,
    parameter integer TAG_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_lut00,
    input wire [7:0] s_lut10,
    input wire [7:0] s_lut01,
    input wire [7:0] s_lut11,
    input wire [FRACTION_BITS:0] s_fx,
    input wire [FRACTION_BITS:0] s_fy,
    input wire s_sof,
    input wire s_eol,
    input wire [TAG_WIDTH-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire [7:0] m_gray,
    output wire m_sof,
    output wire m_eol,
    output wire [TAG_WIDTH-1:0] m_tag,
    output wire m_error
);
    localparam integer PIXEL_WEIGHT_WIDTH = FRACTION_BITS + 8;
    localparam integer INTERP_WIDTH = 2*FRACTION_BITS + 8;
    localparam integer ROUND_WIDTH = INTERP_WIDTH + 1;
    localparam [FRACTION_BITS:0] UNIT = (1 << FRACTION_BITS);

    wire input_error = (FRACTION_BITS < 1) || (FRACTION_BITS > 12) ||
                       (s_fx > UNIT) || (s_fy > UNIT);
    wire [FRACTION_BITS:0] fx_eff = input_error ? {(FRACTION_BITS+1){1'b0}} : s_fx;
    wire [FRACTION_BITS:0] fy_eff = input_error ? {(FRACTION_BITS+1){1'b0}} : s_fy;
    wire [FRACTION_BITS:0] x0 = input_error ? {(FRACTION_BITS+1){1'b0}} : UNIT - s_fx;
    wire [FRACTION_BITS:0] y0 = input_error ? {(FRACTION_BITS+1){1'b0}} : UNIT - s_fy;

    // Stage 1: pixel-by-horizontal-weight products.
    wire [PIXEL_WEIGHT_WIDTH-1:0] lut00_ext = {{(PIXEL_WEIGHT_WIDTH-8){1'b0}}, s_lut00};
    wire [PIXEL_WEIGHT_WIDTH-1:0] lut10_ext = {{(PIXEL_WEIGHT_WIDTH-8){1'b0}}, s_lut10};
    wire [PIXEL_WEIGHT_WIDTH-1:0] lut01_ext = {{(PIXEL_WEIGHT_WIDTH-8){1'b0}}, s_lut01};
    wire [PIXEL_WEIGHT_WIDTH-1:0] lut11_ext = {{(PIXEL_WEIGHT_WIDTH-8){1'b0}}, s_lut11};
    wire [PIXEL_WEIGHT_WIDTH-1:0] x0_ext = {{(PIXEL_WEIGHT_WIDTH-FRACTION_BITS-1){1'b0}}, x0};
    wire [PIXEL_WEIGHT_WIDTH-1:0] fx_ext = {{(PIXEL_WEIGHT_WIDTH-FRACTION_BITS-1){1'b0}}, fx_eff};
    wire [PIXEL_WEIGHT_WIDTH-1:0] s_p00 = lut00_ext * x0_ext;
    wire [PIXEL_WEIGHT_WIDTH-1:0] s_p10 = lut10_ext * fx_ext;
    wire [PIXEL_WEIGHT_WIDTH-1:0] s_p01 = lut01_ext * x0_ext;
    wire [PIXEL_WEIGHT_WIDTH-1:0] s_p11 = lut11_ext * fx_ext;

    // Ready propagates backward through all five registers. clk_en freezes
    // valid, data, and metadata together, and also deasserts input ready.
    reg v0, v1, v2, v3, v4;
    wire r4 = !v4 || m_ready;
    wire r3 = !v3 || r4;
    wire r2 = !v2 || r3;
    wire r1 = !v1 || r2;
    wire r0 = !v0 || r1;
    assign s_ready = rst_n && clk_en && r0;
    // Keep valid and payload stable across a global clock-enable stall. The
    // integrating consumer qualifies the actual transfer with the same CE.
    assign m_valid = v4;

    reg [PIXEL_WEIGHT_WIDTH-1:0] p00_q, p10_q, p01_q, p11_q;
    reg [PIXEL_WEIGHT_WIDTH-1:0] h0_q, h1_q;
    reg [FRACTION_BITS:0] sy0_q, sfy_q;
    reg [FRACTION_BITS:0] fy0_q, fy_q;
    reg [INTERP_WIDTH-1:0] v0_q, v1_q;
    reg [INTERP_WIDTH-1:0] sum_q;

    reg e0_q, e1_q, e2_q, e3_q, e4_q;
    reg sof0_q, sof1_q, sof2_q, sof3_q, sof4_q;
    reg eol0_q, eol1_q, eol2_q, eol3_q, eol4_q;
    reg [TAG_WIDTH-1:0] tag0_q, tag1_q, tag2_q, tag3_q, tag4_q;
    reg [7:0] gray4_q;

    assign m_gray = gray4_q;
    assign m_sof = sof4_q;
    assign m_eol = eol4_q;
    assign m_tag = tag4_q;
    assign m_error = e4_q;

    wire [PIXEL_WEIGHT_WIDTH-1:0] h0_sum = p00_q + p10_q;
    wire [PIXEL_WEIGHT_WIDTH-1:0] h1_sum = p01_q + p11_q;
    wire [INTERP_WIDTH-1:0] h0_ext = {{(INTERP_WIDTH-PIXEL_WEIGHT_WIDTH){1'b0}}, h0_q};
    wire [INTERP_WIDTH-1:0] h1_ext = {{(INTERP_WIDTH-PIXEL_WEIGHT_WIDTH){1'b0}}, h1_q};
    wire [INTERP_WIDTH-1:0] fy0_ext = {{(INTERP_WIDTH-FRACTION_BITS-1){1'b0}}, fy0_q};
    wire [INTERP_WIDTH-1:0] fy_ext = {{(INTERP_WIDTH-FRACTION_BITS-1){1'b0}}, fy_q};
    wire [INTERP_WIDTH-1:0] s_v0 = h0_ext * fy0_ext;
    wire [INTERP_WIDTH-1:0] s_v1 = h1_ext * fy_ext;
    wire [INTERP_WIDTH-1:0] vertical_sum = v0_q + v1_q;
    wire [ROUND_WIDTH-1:0] round_addend = {{INTERP_WIDTH{1'b0}}, 1'b1} << (2*FRACTION_BITS-1);
    wire [ROUND_WIDTH-1:0] rounded_wide = {1'b0, sum_q} + round_addend;
    wire [ROUND_WIDTH-1:0] rounded_pixel = rounded_wide >> (2*FRACTION_BITS);

    // Stage 5 output conversion. The extended quotient permits an explicit
    // saturation check even if a future upstream change violates convexity.
    wire [7:0] final_gray = e3_q ? 8'd0 :
                            (rounded_pixel > 9'd255 ? 8'd255 : rounded_pixel[7:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0;
            p00_q <= 0; p10_q <= 0; p01_q <= 0; p11_q <= 0;
            h0_q <= 0; h1_q <= 0; sy0_q <= 0; sfy_q <= 0;
            fy0_q <= 0; fy_q <= 0;
            v0_q <= 0; v1_q <= 0; sum_q <= 0;
            e0_q <= 0; e1_q <= 0; e2_q <= 0; e3_q <= 0; e4_q <= 0;
            sof0_q <= 0; sof1_q <= 0; sof2_q <= 0; sof3_q <= 0; sof4_q <= 0;
            eol0_q <= 0; eol1_q <= 0; eol2_q <= 0; eol3_q <= 0; eol4_q <= 0;
            tag0_q <= 0; tag1_q <= 0; tag2_q <= 0; tag3_q <= 0; tag4_q <= 0;
            gray4_q <= 0;
        end else if (clk_en) begin
            if (r4) begin
                v4 <= v3;
                if (v3) begin
                    e4_q <= e3_q;
                    sof4_q <= sof3_q;
                    eol4_q <= eol3_q;
                    tag4_q <= tag3_q;
                    gray4_q <= final_gray;
                end
            end
            if (r3) begin
                v3 <= v2;
                if (v2) begin
                    sum_q <= vertical_sum;
                    e3_q <= e2_q;
                    sof3_q <= sof2_q;
                    eol3_q <= eol2_q;
                    tag3_q <= tag2_q;
                end
            end
            if (r2) begin
                v2 <= v1;
                if (v1) begin
                    v0_q <= s_v0;
                    v1_q <= s_v1;
                    e2_q <= e1_q;
                    sof2_q <= sof1_q;
                    eol2_q <= eol1_q;
                    tag2_q <= tag1_q;
                end
            end
            if (r1) begin
                v1 <= v0;
                if (v0) begin
                    h0_q <= h0_sum;
                    h1_q <= h1_sum;
                    fy0_q <= sy0_q;
                    fy_q <= sfy_q;
                    e1_q <= e0_q;
                    sof1_q <= sof0_q;
                    eol1_q <= eol0_q;
                    tag1_q <= tag0_q;
                end
            end
            if (r0) begin
                v0 <= s_valid;
                if (s_valid) begin
                    p00_q <= s_p00;
                    p10_q <= s_p10;
                    p01_q <= s_p01;
                    p11_q <= s_p11;
                    sy0_q <= y0;
                    sfy_q <= fy_eff;
                    e0_q <= input_error;
                    sof0_q <= s_sof;
                    eol0_q <= s_eol;
                    tag0_q <= s_tag;
                end
            end
        end
    end
endmodule
