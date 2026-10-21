// ---------------------------------------------------------------------------
// gw2a_ips_reciprocal_lut : packaged, licensable wrapper for the ips_reciprocal_lut core.
// Family arith.  12-bit reciprocal ROM with one Newton-Raphson refinement step and exact division check flag
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_reciprocal_lut #(
    parameter FRAC = 12,
    parameter IDXB = 3,
    parameter WBITS = 8
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire start,
    input wire [FRAC-1:0] den,
    output wire busy,
    output wire [FRAC+1:0] recip,
    output wire [FRAC+1:0] r0,
    output wire [FRAC+1:0] resid,
    output wire [IDXB-1:0] ridx,
    output wire [WBITS-1:0] rwt,
    output wire [3:0] rnshift,
    output wire nflag,
    output wire exact,
    output wire err,
    output wire sticky,
    output wire valid,
    output wire [7:0] done,
    output wire [3:0] iter,
    output wire [3:0] stage
);

    ips_reciprocal_lut #(
        .FRAC(FRAC),
        .IDXB(IDXB),
        .WBITS(WBITS)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .start(start),
        .den(den),
        .busy(busy),
        .recip(recip),
        .r0(r0),
        .resid(resid),
        .ridx(ridx),
        .rwt(rwt),
        .rnshift(rnshift),
        .nflag(nflag),
        .exact(exact),
        .err(err),
        .sticky(sticky),
        .valid(valid),
        .done(done),
        .iter(iter),
        .stage(stage)
    );

endmodule
