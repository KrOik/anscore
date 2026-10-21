// ============================================================================
// lfsr_prng -- 32-bit Galois LFSR PRNG + self-synchronous scrambler pair
// (wave2 idx39, TAG LFSR).
//
// lfsr_prng: maximal-length Galois LFSR, polynomial x^32+x^22+x^2+x+1
//   (tap set {32,22,2,1}, XAPP052 primitive table).  Right-shift form:
//       fb = state[0]; state <= (state >> 1) ^ (fb ? 32'h8020_0003 : 0)
//   seed_wr loads `seed`; step advances one step per clk_en beat.
//
// lfsr_scrambler / lfsr_descrambler: self-synchronous (cipher-feedback)
//   byte scrambler pair sharing the same 32-bit state register.
//       keystream k = s[7:0] ^ s[15:8] ^ s[23:16] ^ s[31:24]
//       scrambler   : c = din ^ k ; s <= {s[23:0], c}
//       descrambler : m = din ^ k ; s <= {s[23:0], din}   (shifts CIPHER in)
//   Identical state update -> descrambler re-syncs after 4 cipher bytes
//   regardless of its initial state (classic self-synchronous property).
//   in_valid beat -> dout/out_valid registered the next clk_en beat.
//
// All registers clk_en gated (T2); no RAM, no multipliers.
// ============================================================================
module lfsr_prng (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        seed_wr,
    input  wire [31:0] seed,
    input  wire        step,
    output reg  [31:0] state
);
    localparam [31:0] TAPS = 32'h8020_0003;   // taps {32,22,2,1}
    wire [31:0] nxt = state[0] ? (({1'b0, state[31:1]}) ^ TAPS)
                               :  {1'b0, state[31:1]};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= 32'h0000_0001;
        end else if (clk_en) begin
            if (seed_wr)   state <= seed;
            else if (step) state <= nxt;
        end
    end
endmodule

module lfsr_scrambler (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        seed_wr,
    input  wire [31:0] seed,
    input  wire        in_valid,
    input  wire [7:0]  din,
    output reg         out_valid,
    output reg  [7:0]  dout,
    output wire [31:0] state_o
);
    reg [31:0] s;
    wire [7:0] k = s[7:0] ^ s[15:8] ^ s[23:16] ^ s[31:24];
    wire [7:0] c = din ^ k;
    assign state_o = s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s         <= 32'h0000_0001;
            dout      <= 8'd0;
            out_valid <= 1'b0;
        end else if (clk_en) begin
            out_valid <= in_valid && !seed_wr;
            if (seed_wr) begin
                s <= seed;
            end else if (in_valid) begin
                s    <= {s[23:0], c};
                dout <= c;
            end
        end
    end
endmodule

module lfsr_descrambler (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        seed_wr,
    input  wire [31:0] seed,
    input  wire        in_valid,
    input  wire [7:0]  din,
    output reg         out_valid,
    output reg  [7:0]  dout,
    output wire [31:0] state_o
);
    reg [31:0] s;
    wire [7:0] k = s[7:0] ^ s[15:8] ^ s[23:16] ^ s[31:24];
    wire [7:0] m = din ^ k;
    assign state_o = s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s         <= 32'h0000_0001;
            dout      <= 8'd0;
            out_valid <= 1'b0;
        end else if (clk_en) begin
            out_valid <= in_valid && !seed_wr;
            if (seed_wr) begin
                s <= seed;
            end else if (in_valid) begin
                s    <= {s[23:0], din};   // shifts ciphertext in
                dout <= m;
            end
        end
    end
endmodule
