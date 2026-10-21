// ============================================================================
// bnn_dense -- binarised dense (fully-connected) layer (wave2 idx36, TAG BDN).
//
//   N neurons x NIN binary inputs.  Per neuron:
//       pc   = popcount( ~(in_vec ^ w[n]) )          // XNOR match count 0..NIN
//       sum  = pc + bias[n]  (bias signed, -128..127)
//       out[n] = (sum >= 0)
//
// Weight/bias programming: synchronous write ports (one clk_en beat each).
//   w_en & w_addr & w_data[NIN-1:0]  -> weight word of neuron w_addr
//   b_en & b_addr & b_data[7:0] (signed) -> bias of neuron b_addr
// Storage is a small DFF register file (N x NIN + N x 8 bits) -- no RAM.
//
// Streaming: in_valid beat -> out/out_valid registered the next clk_en beat
// (1-beat latency, fully pipelined: back-to-back in_valid is fine).
//
// All registers clk_en gated (T2); no multipliers (T4).
// ============================================================================
module bnn_dense #(
    parameter NIN = 32,
    parameter N   = 4,
    parameter AW  = (N > 1) ? $clog2(N) : 1
)(
    input  wire             clk,
    input  wire             clk_en,
    input  wire             rst_n,
    // weight write port
    input  wire             w_en,
    input  wire [AW-1:0]    w_addr,
    input  wire [NIN-1:0]   w_data,
    // bias write port
    input  wire             b_en,
    input  wire [AW-1:0]    b_addr,
    input  wire signed [7:0] b_data,
    // stream
    input  wire             in_valid,
    input  wire [NIN-1:0]   in_vec,
    output reg              out_valid,
    output reg  [N-1:0]     out
);
    // --------------------------------------------------------------
    // register files
    // --------------------------------------------------------------
    reg [NIN-1:0]      wmem [0:N-1];
    reg signed [7:0]   bmem [0:N-1];
    integer wi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (wi = 0; wi < N; wi = wi + 1) begin
                wmem[wi] <= {NIN{1'b0}};
                bmem[wi] <= 8'sd0;
            end
        end else if (clk_en) begin
            if (w_en) wmem[w_addr] <= w_data;
            if (b_en) bmem[b_addr] <= b_data;
        end
    end

    // --------------------------------------------------------------
    // combinational neuron evaluation
    // --------------------------------------------------------------
    function [5:0] pc32;
        input [NIN-1:0] v;
        integer i;
        begin
            pc32 = 6'd0;
            for (i = 0; i < NIN; i = i + 1) pc32 = pc32 + {5'd0, v[i]};
        end
    endfunction

    genvar gi;
    wire [N-1:0] outc;
    generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_n
        wire [NIN-1:0] mt  = ~(in_vec ^ wmem[gi]);
        wire [5:0]     pc  = pc32(mt);
        // pc in [0,32] (6b), bias in [-128,127] (8s) -> sum fits 9b signed
        wire signed [8:0] sum = $signed({3'b000, pc}) +
                                $signed({bmem[gi][7], bmem[gi]});
        assign outc[gi] = ~sum[8];              // sum >= 0
    end
    endgenerate

    // --------------------------------------------------------------
    // output register (1-beat latency)
    // --------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out       <= {N{1'b0}};
            out_valid <= 1'b0;
        end else if (clk_en) begin
            out_valid <= in_valid;
            if (in_valid) out <= outc;
        end
    end
endmodule
