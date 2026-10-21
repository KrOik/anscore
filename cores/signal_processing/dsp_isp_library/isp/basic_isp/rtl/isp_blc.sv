// ============================================================================
// ISP-08 stage 1: black-level correction (BLC).
// Per-channel unsigned offset subtract with clamp at zero:
//     out_c = (in_c >= off_c) ? in_c - off_c : 0
//
// Elastic II=1 stage, one cycle latency.  Offsets are packed LSB-first:
// cfg_blc[c*BITS +: BITS] is channel c (CH=3: c0=B, c1=G, c2=R matching
// {R,G,B} MSB->LSB pixel packing).  Channels >= CH are stored, unused.
// cfg_commit latches the whole field atomically; the integrating top only
// pulses it while the pipeline is empty, so the contract here is simply
// "no in-flight pixels during commit".
// ============================================================================
module isp_blc #(
    parameter BITS = 8,
    parameter CH   = 3,            // 1 = gray, 3 = packed {R,G,B}
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
    input  wire [3*BITS-1:0] cfg_blc
);
    reg  [3*BITS-1:0] off;
    wire advance = !m_tvalid || m_tready;
    assign s_tready = rst_n && advance;
    wire take = s_tvalid && s_tready;

    genvar c;
    wire [CH*BITS-1:0] corrected;
    generate for (c = 0; c < CH; c = c + 1) begin: chc
        wire [BITS-1:0] d  = s_tdata[c*BITS +: BITS];
        wire [BITS-1:0] o  = off[c*BITS +: BITS];
        assign corrected[c*BITS +: BITS] = (d >= o) ? (d - o) : {BITS{1'b0}};
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            off <= {3*BITS{1'b0}};
            m_tvalid <= 0; m_tuser <= 0; m_tlast <= 0;
        end else begin
            if (cfg_commit) off <= cfg_blc;
            if (advance) begin
                m_tvalid <= take;
                if (take) begin
                    m_tdata <= corrected;
                    m_tuser <= s_tuser;
                    m_tlast <= s_tlast;
                end
            end
        end
    end
    initial begin
        if ((BITS != 8 && BITS != 10) || (CH != 1 && CH != 3))
            $fatal(1, "unsupported isp_blc parameters");
    end
endmodule
