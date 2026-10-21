// ============================================================================
// gw2a_w2_mot_bbox -- wave2 selftest IP wrapper (GW2A-18C, Tang Primer 20K)
// Wraps st_mot_bbox: internal stimulus + DUT + golden-digest comparison.
// Validated: selftest unit BBOX, FNV-1a digest 221B2F39,
//   iverilog unit sim + aggregate (full/lo/hi UNIT_EN masks) PASS.
// ============================================================================
module gw2a_w2_mot_bbox (
    input  wire        clk,
    input  wire        rst_n,    // active-low async reset
    input  wire        clk_en,   // step enable; tie 1 for full rate
    input  wire        start,    // 1-beat start pulse (clk_en domain)
    output wire        done,
    output wire        pass,
    output wire [31:0] digest,
    output wire [15:0] cycles
);
    st_mot_bbox u_cell (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .done(done), .pass(pass), .digest(digest), .cycles(cycles)
    );
endmodule
