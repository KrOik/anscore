// ============================================================================
// qei_dec -- quadrature encoder interface, x4 decode.
//
// count changes on every edge of A and B (4 counts per quadrature cycle).
// Forward (A leads B) increments, reverse decrements; `dir` reports the last
// step direction (1 = forward). A rising edge on `qidx` latches count into
// idx_latch and pulses idx_evt; when idx_rst=1 the count is also cleared.
// A step coincident with the index edge is dropped (documented limit).
// All registers clk_en gated.
// ============================================================================
module qei_dec (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        qa,
    input  wire        qb,
    input  wire        qidx,
    input  wire        idx_rst,
    output reg  [31:0] count,
    output reg         dir,
    output reg         step_v,
    output reg  [31:0] idx_latch,
    output reg         idx_evt
);

reg a_d, b_d, i_d;

wire ar =  qa && !a_d;
wire af = !qa &&  a_d;
wire br =  qb && !b_d;
wire bf = !qb &&  b_d;

wire up = (ar && !qb) || (af && qb) || (br && qa) || (bf && !qa);
wire dn = (ar &&  qb) || (af && !qb) || (br && !qa) || (bf && qa);
wire ie = qidx && !i_d;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        a_d <= 1'b0; b_d <= 1'b0; i_d <= 1'b0;
        count <= 32'd0; dir <= 1'b1; step_v <= 1'b0;
        idx_latch <= 32'd0; idx_evt <= 1'b0;
    end else if (clk_en) begin
        a_d <= qa;
        b_d <= qb;
        i_d <= qidx;
        step_v  <= up | dn;
        idx_evt <= ie;
        if (ie) begin
            idx_latch <= count;
            if (idx_rst) count <= 32'd0;
            else if (up && !dn) begin count <= count + 32'd1; dir <= 1'b1; end
            else if (dn && !up) begin count <= count - 32'd1; dir <= 1'b0; end
        end else if (up && !dn) begin
            count <= count + 32'd1;
            dir   <= 1'b1;
        end else if (dn && !up) begin
            count <= count - 32'd1;
            dir   <= 1'b0;
        end
    end
end

endmodule
