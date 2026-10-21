// ============================================================================
// gw2a_img_sobel_edge -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Cores: sobel_edge+win3x3_gen+line_buf_ram  (src/sobel_edge.v, src/win3x3_gen.v, src/line_buf_ram.v)
// Board-validated: selftest unit 2 (SOB), golden digest E1762120,
//   bitstream cores/image_processing/window/build_oss/imgwin_20k.fs
// Border policy: edge replication (clamp): tap(r,c) = I[clamp(y+r-1,0,H-1)][clamp(x+c-1,0,W-1)]; identical in tools/golden_model.py
// ============================================================================
module gw2a_img_sobel_edge #(
    parameter IMG_W = 16,
    parameter IMG_H = 16,
    parameter THRESH = 8'd96   // binary threshold on magnitude
)(
    input  wire clk           , // system clock
    input  wire rst_n         , // active-low async reset
    input  wire clk_en        , // step enable; tie 1 for full rate
    input  wire [7:0] pix           , // gray pixel in
    input  wire pix_valid     , // pixel beat valid
    input  wire new_line      , // 1-beat pulse before each input row
    output wire [7:0] mag_out       , // edge magnitude, saturating
    output wire [7:0] bin_out       , // 8'hFF/8'h00 thresholded edge
    output wire out_valid     , // output valid
    output wire new_line_out  , // first pixel of output row
    output wire done            // frame flush complete
);

    wire [71:0] win_w;
    wire        wv_w, nlo_w;

    win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_gen (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(pix), .pix_valid(pix_valid), .new_line(new_line),
        .win(win_w), .win_valid(wv_w),
        .new_line_out(nlo_w), .done(done)
    );

    sobel_edge #(.THRESH(THRESH)) u_f (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .win(win_w), .win_valid(wv_w), .new_line_out(nlo_w),
        .mag_out(mag_out), .bin_out(bin_out),
        .out_valid(out_valid), .nl_out(new_line_out)
    );
endmodule
