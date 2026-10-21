// ============================================================================
// prbs31 -- wave2 idx33 "PRBS": PRBS-31 generator + checker pair.
//
// Fixed polynomial: x^31 + x^28 + 1 (Fibonacci form).
//   generator : out = r[0]; fb = r[30] ^ r[27]; r <= {fb, r[30:1]}
//   => emitted bit stream obeys  b[n] = b[n-28] ^ b[n-31].
//
// Checker: sliding 31-bit window w over received bits (w[0]=latest,
// w[30]=oldest).  While chk_sync=1 each chk_en beat shifts the received
// bit into w without comparison; after 31 bits `synced` asserts.
// With chk_sync=0 each chk_en beat predicts the next bit as
// exp = w[30] ^ w[27], counts a bit error on mismatch, then shifts the
// received bit in (the window self-heals after 31 clean bits).
//
// Ports:
//   gen_en   advance generator one bit/beat; gen_bit is combinational.
//   seed_we  load generator state from seed (seed==0 is the illegal
//            all-zero lockup state -- integrator must not load it).
//   chk_en   checker consumes chk_bit this beat.
//   chk_sync load-window mode (first 31 received bits).
//   err_cnt  bit errors since rst_n / sync restart (saturating 16-bit).
//   bit_cnt  checked (non-sync) bits consumed (saturating 16-bit).
//   synced   window fully loaded.
//
// All registers clk_en gated (T2).
// ============================================================================
module prbs31 (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        seed_we,
    input  wire [30:0] seed,
    input  wire        gen_en,
    output wire        gen_bit,

    input  wire        chk_en,
    input  wire        chk_sync,
    input  wire        chk_bit,

    output reg  [15:0] err_cnt,
    output reg  [15:0] bit_cnt,
    output reg         synced
);

reg  [30:0] gen_r;
reg  [30:0] chk_r;
reg  [5:0]  sync_cnt;

wire gen_fb = gen_r[30] ^ gen_r[27];
assign gen_bit = gen_r[0];

wire exp_bit = chk_r[30] ^ chk_r[27];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        gen_r    <= 31'h2AA55AA5;
        chk_r    <= 31'b0;
        sync_cnt <= 6'd0;
        err_cnt  <= 16'd0;
        bit_cnt  <= 16'd0;
        synced   <= 1'b0;
    end else if (clk_en) begin
        if (seed_we)
            gen_r <= seed;
        else if (gen_en)
            gen_r <= {gen_fb, gen_r[30:1]};

        if (chk_en) begin
            chk_r <= {chk_bit, chk_r[30:1]};
            if (chk_sync) begin
                if (sync_cnt < 6'd31) sync_cnt <= sync_cnt + 6'd1;
                if (sync_cnt == 6'd30) synced <= 1'b1;
                if (!synced) begin
                    err_cnt <= 16'd0;
                    bit_cnt <= 16'd0;
                end
            end else begin
                if (bit_cnt != 16'hFFFF) bit_cnt <= bit_cnt + 16'd1;
                if (chk_bit != exp_bit && err_cnt != 16'hFFFF)
                    err_cnt <= err_cnt + 16'd1;
            end
        end
    end
end

endmodule
