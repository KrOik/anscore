// ============================================================================
// gw2a_img_win3x3_gen -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Cores: win3x3_gen+line_buf_ram  (src/win3x3_gen.v, src/line_buf_ram.v)
// Board-validated: selftest unit 0 (WIN), golden digest BD71944D,
//   bitstream cores/image_processing/window/build_oss/imgwin_20k.fs
// Border policy: edge replication (clamp): tap(r,c) = I[clamp(y+r-1,0,H-1)][clamp(x+c-1,0,W-1)]; identical in tools/golden_model.py
// ============================================================================
module gw2a_img_win3x3_gen #(
    parameter IMG_W = 16,  // pixels per line (line-buffer depth)
    parameter IMG_H = 16   // lines per frame
)(
    input  wire clk           , // system clock
    input  wire rst_n         , // active-low async reset
    input  wire clk_en        , // step enable; tie 1 for full rate
    input  wire [7:0] pix           , // gray pixel in
    input  wire pix_valid     , // pixel beat valid
    input  wire new_line      , // 1-beat pulse before each input row
    output wire [71:0] win           , // 9 taps, win[i*8+:8] = tap(i), i=r*3+c
    output wire win_valid     , // window emitted this beat
    output wire new_line_out  , // first window of output row
    output wire done            // frame flush complete
);

    win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_core (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(pix), .pix_valid(pix_valid), .new_line(new_line),
        .win(win), .win_valid(win_valid),
        .new_line_out(new_line_out), .done(done)
    );
endmodule
