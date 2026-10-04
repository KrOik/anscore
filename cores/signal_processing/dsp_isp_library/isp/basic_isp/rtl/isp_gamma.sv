// ============================================================================
// ISP-08 stage 4: gamma via piecewise-linear LUT.
//
// 32-segment PWL, 33 generated nodes (rtl/gamma_table.vh, produced by
// models/reference.py emit_gamma_vh - do not edit the .vh by hand):
//   idx  = v[BITS-1 -: 5]         (top 5 bits, 0..31)
//   frac = v[BITS-6:0]            (BITS-5 low bits, STEP = 2^(BITS-5))
//   y0 = node[sel][idx], y1 = node[sel][idx+1]
//   out = y0 + ((y1 - y0) * frac + STEP/2) >> (BITS-5)     (round-half-up)
// sel: 0 = bypass, 1 = encode x^(1/2.2), 2 = decode x^2.2.  sel=3 is an
// illegal config (rejected upstream by cfg_error; treated as bypass here).
//
// The node tables are combinational ROM (case functions) - no RAM at all,
// so no CE-gated read hazard; the interpolation multiply is LUT fabric.
// Elastic II=1 stage, one cycle latency.  Same cfg_commit contract.
// ============================================================================
module isp_gamma #(
    parameter BITS = 8,
    parameter CH   = 3,
    parameter MPX  = (BITS<1) ? 1 : ((1<<BITS)-1)
)(
    input  wire clk, rst_n,
    input  wire [CH*BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output reg  [CH*BITS-1:0] m_tdata,
    output reg  m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    input  wire cfg_commit,
    input  wire [1:0] cfg_sel
);
    `include "gamma_table.vh"

    localparam FB = BITS - 5;                // fraction bits: 3 or 5
    reg [1:0] sel;
    wire advance = !m_tvalid || m_tready;
    assign s_tready = rst_n && advance;
    wire take = s_tvalid && s_tready;

    function automatic [BITS-1:0] node(input [1:0] s, input [5:0] i);
        begin
            if (BITS == 10)
                node = (s == 2'd2) ? gamma_node10_dec(i) : gamma_node10_enc(i);
            else
                node = (s == 2'd2) ? gamma_node8_dec(i)  : gamma_node8_enc(i);
        end
    endfunction

    genvar c;
    wire [CH*BITS-1:0] mapped;
    generate for (c = 0; c < CH; c = c + 1) begin: chc
        wire [BITS-1:0] d    = s_tdata[c*BITS +: BITS];
        wire [4:0]      idx  = d[BITS-1 -: 5];
        wire [FB-1:0]   frac = d[FB-1:0];
        wire [BITS-1:0] y0   = node(sel, {1'b0, idx});
        wire [BITS-1:0] y1   = node(sel, {1'b0, idx} + 6'd1);
        wire [BITS:0]   dy   = {1'b0, y1} - {1'b0, y0};   // nodes monotonic
        // Full-width product: context BITS+FB+1 exceeds the true bound
        // (2^(BITS+1)-1)(2^FB-1) < 2^(BITS+FB+1).
        wire [BITS+FB:0] prod = dy * frac;
        wire [BITS+1:0] interp = {2'b00, y0} +
            ((prod + (1 << (FB-1))) >> FB);
        assign mapped[c*BITS +: BITS] =
            (sel == 2'd0) ? d
                          : ((interp > MPX) ? MPX[BITS-1:0]
                                            : interp[BITS-1:0]);
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            sel <= 2'd0;
            m_tvalid <= 0; m_tuser <= 0; m_tlast <= 0;
        end else begin
            if (cfg_commit) sel <= cfg_sel;
            if (advance) begin
                m_tvalid <= take;
                if (take) begin
                    m_tdata <= mapped;
                    m_tuser <= s_tuser;
                    m_tlast <= s_tlast;
                end
            end
        end
    end
    initial begin
        if ((BITS != 8 && BITS != 10) || (CH != 1 && CH != 3))
            $fatal(1, "unsupported isp_gamma parameters");
    end
endmodule
