// ============================================================================
// gw2a_img_threshold_bin -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Cores: threshold_bin  (src/threshold_bin.v)
// Board-validated: selftest unit 5 (THR), golden digest 9FFADFC0,
//   bitstream cores/image_processing/window/build_oss/imgwin_20k.fs
// Border policy: edge replication (clamp): tap(r,c) = I[clamp(y+r-1,0,H-1)][clamp(x+c-1,0,W-1)]; identical in tools/golden_model.py
// ============================================================================
module gw2a_img_threshold_bin #(
    parameter THRESH = 8'd128   // binarization threshold
)(
    input  wire clk           , // system clock
    input  wire rst_n         , // active-low async reset
    input  wire clk_en        , // step enable; tie 1 for full rate
    input  wire [7:0] pix           , // gray pixel in
    input  wire pix_valid     , // pixel beat valid
    input  wire new_line      , // row-start pulse (passed through)
    output wire [7:0] pix_out       , // 8'hFF/8'h00 out
    output wire out_valid     , // output valid
    output wire new_line_out    // delayed row marker
);

    threshold_bin #(.THRESH(THRESH)) u_core (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(pix), .pix_valid(pix_valid), .new_line(new_line),
        .pix_out(pix_out), .out_valid(out_valid),
        .new_line_out(new_line_out)
    );
endmodule
