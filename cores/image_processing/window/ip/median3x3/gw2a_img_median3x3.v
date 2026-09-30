// ============================================================================
// gw2a_img_median3x3 -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Cores: median3x3+win3x3_gen+line_buf_ram  (src/median3x3.v, src/win3x3_gen.v, src/line_buf_ram.v)
// Board-validated: selftest unit 3 (MED), golden digest A3A98A3C,
//   bitstream cores/image_processing/window/build_oss/imgwin_20k.fs
// Border policy: edge replication (clamp): tap(r,c) = I[clamp(y+r-1,0,H-1)][clamp(x+c-1,0,W-1)]; identical in tools/golden_model.py
// ============================================================================
module gw2a_img_median3x3 #(
    parameter IMG_W = 16,
    parameter IMG_H = 16 
)(
    input  wire clk           , // system clock
    input  wire rst_n         , // active-low async reset
    input  wire clk_en        , // step enable; tie 1 for full rate
    input  wire [7:0] pix           , // gray pixel in
    input  wire pix_valid     , // pixel beat valid
    input  wire new_line      , // 1-beat pulse before each input row
    output wire [7:0] pix_out       , // median pixel out
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

    median3x3 u_f (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .win(win_w), .win_valid(wv_w), .new_line_out(nlo_w),
        .pix_out(pix_out), .out_valid(out_valid), .nl_out(new_line_out)
    );
endmodule
