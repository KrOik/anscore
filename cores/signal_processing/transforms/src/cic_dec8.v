// ============================================================================
// cic_dec8: CIC decimator, N=3 stages, R=8, M=1.
//   3 integrators at fs -> decimate-by-8 -> 3 combs at fs/8.
// Datapath: signed 17-bit wrapping throughout (input 8b signed + growth
// N*log2(R)=9b => 17b per Hogenauer; max gain 8^3*127 < 2^16 margin).
// out_valid strobes once per 8 input beats.
// ============================================================================
module cic_dec8 (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire signed [7:0]  din,
    output reg         out_valid,
    output reg  signed [16:0] dout
);

reg signed [16:0] i1, i2, i3;
reg signed [16:0] c1d, c2d, c3d;
reg [2:0] cnt;

wire signed [16:0] din_e = { {9{din[7]}}, din };
wire signed [16:0] i1n = i1 + din_e;
wire signed [16:0] i2n = i2 + i1n;
wire signed [16:0] i3n = i3 + i2n;

// comb differences evaluated on the decimated value i3n (only used at cnt==7)
wire signed [16:0] c1 = i3n - c1d;
wire signed [16:0] c2 = c1 - c2d;
wire signed [16:0] c3 = c2 - c3d;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        i1 <= 17'sd0; i2 <= 17'sd0; i3 <= 17'sd0;
        c1d <= 17'sd0; c2d <= 17'sd0; c3d <= 17'sd0;
        cnt <= 3'd0; out_valid <= 1'b0; dout <= 17'sd0;
    end else if (clk_en) begin
        out_valid <= 1'b0;
        if (in_valid) begin
            i1 <= i1n; i2 <= i2n; i3 <= i3n;
            if (cnt == 3'd7) begin
                cnt <= 3'd0;
                c1d <= i3n; c2d <= c1; c3d <= c2;
                dout <= c3;
                out_valid <= 1'b1;
            end else begin
                cnt <= cnt + 3'd1;
            end
        end
    end
end

endmodule
