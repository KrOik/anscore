// ============================================================================
// ISP-08 stage 2: external white-balance gain application.
// Per-channel UQ4.8 gain with round-half-up and saturation:
//     out_c = min(MPX, (in_c * gain_c + 128) >> 8)
// gain_c = 256 is unity; the 12-bit field spans [0, 15.996].
//
// This stage ONLY applies externally supplied gains.  Auto white-balance
// *estimation* is a separate concern: isp_awb_stats produces the per-channel
// post-BLC frame sums and models/reference.py gray_world_gains() computes
// the UQ4.8 values a host would commit here through the atomic config.
//
// Elastic II=1 stage, one cycle latency.  cfg_wb packed LSB-first:
// cfg_wb[c*12 +: 12] is channel c.  Same cfg_commit contract as isp_blc.
// ============================================================================
module isp_wb_gain #(
    parameter BITS = 8,
    parameter CH   = 3,
    parameter MPX  = (BITS<1) ? 1 : ((1<<BITS)-1),
    parameter GW   = 12            // gain field width (UQ4.8)
)(
    input  wire clk, rst_n,
    input  wire [CH*BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output reg  [CH*BITS-1:0] m_tdata,
    output reg  m_tvalid, m_tuser, m_tlast,
    input  wire m_tready,
    input  wire cfg_commit,
    input  wire [3*GW-1:0] cfg_wb
);
    localparam PW = BITS + GW;               // product width, <= 22
    localparam [GW-1:0] UNITY = 256;         // UQ4.8 gain = 1.0
    reg  [3*GW-1:0] gain;
    wire advance = !m_tvalid || m_tready;
    assign s_tready = rst_n && advance;
    wire take = s_tvalid && s_tready;

    genvar c;
    wire [CH*BITS-1:0] scaled;
    generate for (c = 0; c < CH; c = c + 1) begin: chc
        wire [BITS-1:0] d = s_tdata[c*BITS +: BITS];
        wire [GW-1:0]   g = gain[c*GW +: GW];
        wire [PW-1:0]   prod = d * g;
        wire [PW-8:0]   rounded = (prod + 9'd128) >> 8;
        assign scaled[c*BITS +: BITS] =
            (rounded > MPX) ? MPX[BITS-1:0] : rounded[BITS-1:0];
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            gain <= {3{UNITY}};
            m_tvalid <= 0; m_tuser <= 0; m_tlast <= 0;
        end else begin
            if (cfg_commit) gain <= cfg_wb;
            if (advance) begin
                m_tvalid <= take;
                if (take) begin
                    m_tdata <= scaled;
                    m_tuser <= s_tuser;
                    m_tlast <= s_tlast;
                end
            end
        end
    end
    initial begin
        if ((BITS != 8 && BITS != 10) || (CH != 1 && CH != 3))
            $fatal(1, "unsupported isp_wb_gain parameters");
    end
endmodule
