// ============================================================================
// isp_gamma -- 256-entry gamma LUT applied per RGB channel, streaming.
//
// Three identical 256x8 LUT banks (w2_dpram -> DPX9B, T9-safe); the write
// port broadcasts to all three so R/G/B share one gamma curve.
//   lut_we/lut_addr/lut_data : table load port (write while not streaming,
//                              or anytime -- port A is independent)
//   pix24/pix_valid/new_line : pixel stream in
//   pix24_out/out_valid/nl_out : LUT[pix] stream out, one clk_en beat of
//                                latency (w2_dpram registered DOB)
// All registers clk_en gated (T2).  BSRAM: 3 blocks.
// ============================================================================
module isp_gamma (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        lut_we,
    input  wire [7:0]  lut_addr,
    input  wire [7:0]  lut_data,
    input  wire [23:0] pix24,        // {R,G,B}
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [23:0] pix24_out,    // {LUT[R],LUT[G],LUT[B]}
    output reg         out_valid,
    output reg         nl_out
);
    wire [7:0] qr, qg, qb;

    w2_dpram #(.W(8), .DEPTH(256), .AW(8)) u_lut_r (
        .clk(clk), .clk_en(clk_en),
        .we(lut_we), .waddr(lut_addr), .wdata(lut_data),
        .re(pix_valid), .raddr(pix24[23:16]), .q(qr));
    w2_dpram #(.W(8), .DEPTH(256), .AW(8)) u_lut_g (
        .clk(clk), .clk_en(clk_en),
        .we(lut_we), .waddr(lut_addr), .wdata(lut_data),
        .re(pix_valid), .raddr(pix24[15:8]), .q(qg));
    w2_dpram #(.W(8), .DEPTH(256), .AW(8)) u_lut_b (
        .clk(clk), .clk_en(clk_en),
        .we(lut_we), .waddr(lut_addr), .wdata(lut_data),
        .re(pix_valid), .raddr(pix24[7:0]), .q(qb));

    // w2_dpram DOB is registered: q is valid one clk_en beat after the
    // pix_valid/re beat; pix24_out registers it one further beat later, so
    // out_valid must be pix_valid delayed by TWO beats to stay aligned.
    reg pv_d1, nl_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pv_d1     <= 1'b0;
            nl_d1     <= 1'b0;
            pix24_out <= 24'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            pv_d1     <= pix_valid;
            nl_d1     <= new_line;
            pix24_out <= {qr, qg, qb};
            out_valid <= pv_d1;
            nl_out    <= nl_d1;
        end
    end
endmodule
