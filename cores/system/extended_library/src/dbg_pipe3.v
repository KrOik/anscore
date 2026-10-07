// ============================================================================
// dbg_pipe3 -- tapeout-debug item A10: three-stage pipeline with per-stage
// datapath bypass.
//
//   din -> [S0: rol1(x)+16'h1021] -> [S1: (x^16'h5A5A)+3] -> [S2: ~x+x[7:0]] -> yout
//
// bypass[i]=1 replaces stage i's transform with a feed-forward of its input,
// WITHOUT changing pipeline latency (stages stay registered) -- this lets a
// failure be bisected stage-by-stage while timing behaviour is unchanged.
//
// kick is a 1-beat launch; y0/y1/y2 are the live stage registers so the host
// can read the residue at every stage.
// ============================================================================
module dbg_pipe3 (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        kick,
    input  wire [15:0] din,
    input  wire [2:0]  bypass,
    output reg  [15:0] y0,
    output reg  [15:0] y1,
    output reg  [15:0] y2,
    output reg         valid
);

function [15:0] f0; input [15:0] x; begin f0 = {x[14:0], x[15]} + 16'h1021; end endfunction
function [15:0] f1; input [15:0] x; begin f1 = (x ^ 16'h5A5A) + 16'd3;      end endfunction
function [15:0] f2; input [15:0] x; begin f2 = ~x + {8'd0, x[7:0]};         end endfunction

wire [15:0] s0 = bypass[0] ? din : f0(din);
wire [15:0] s1 = bypass[1] ? y0  : f1(y0);
wire [15:0] s2 = bypass[2] ? y1  : f2(y1);

reg [2:0] vpipe;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        y0 <= 16'd0; y1 <= 16'd0; y2 <= 16'd0;
        vpipe <= 3'd0; valid <= 1'b0;
    end else if (clk_en) begin
        vpipe <= {vpipe[1:0], kick};
        valid <= vpipe[2];
        if (kick)      y0 <= s0;
        if (vpipe[0])  y1 <= s1;
        if (vpipe[1])  y2 <= s2;
    end
end

endmodule
