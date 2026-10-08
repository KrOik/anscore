// ============================================================================
// st_lfsr_prng -- selftest cell for lfsr_prng + scrambler pair (idx39, LFSR).
//
// Schedule (t = clk_en beats while running):
//   t=0        seed_wr all: prng<-32'h0000ACE1, scr/dscr<-32'h1BADB002
//   t=1..16    prng step; t=2..17 fold state[7:0],[15:8],[23:16],[31:24]
//              (16 post-step states -> 64 bytes)
//   t=20..35   scramble pt[i]=i*17+0x55 (i=t-20); collect ciphertext at
//              t=21..36 -> cbuf, fold
//   t=40..55   descramble cbuf (correct seed) -> fold m_i, check == pt[i]
//   t=60       reseed descrambler with WRONG seed 32'h0BADF00D
//   t=64..79   replay cbuf -> fold m2_i; self-sync check: m2_i==pt[i] i>=4
//              (first 4 outputs garbage -- deterministic, in golden)
// done at ~t=84.  Internal checks: round-trip pass1 exact, pass2 synced
// from byte 4, byte counts exact.
// EXP comes from tools/golden_acc.py only (trap T1).
// ============================================================================
module st_lfsr_prng (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
`include "w2_fnv.vh"

    localparam [31:0] EXP       = 32'h9867D947;  // golden_acc.py LFSR
    localparam [31:0] PRNG_SEED = 32'h0000_ACE1;
    localparam [31:0] SCR_SEED  = 32'h1BAD_B002;
    localparam [31:0] BAD_SEED  = 32'h0BAD_F00D;

    reg        running;
    reg [6:0]  t;
    reg [31:0] dg;
    reg        ok;
    reg [4:0]  nscr, nd1, nd2;
    reg [7:0]  cbuf [0:15];
    reg [31:0] dbg_data;
    reg [2:0]  dbg_cnt;

    wire dut_ce = (clk_en && running) || !rst_n;

    // ---------------- stimulus -----------------------------------------
    wire        sd_wr  = running && (t == 7'd0);
    wire        pr_step = running && (t >= 7'd1) && (t <= 7'd16);
    wire        scr_v  = running && (t >= 7'd20) && (t <= 7'd35);
    wire        d1_v   = running && (t >= 7'd40) && (t <= 7'd55);
    wire        d2_v   = running && (t >= 7'd64) && (t <= 7'd79);
    wire        dseed2 = running && (t == 7'd60);

    wire [3:0]  pi   = t[3:0] - 4'd4;             // t-20 for t=20..35
    wire [7:0]  pt_i = ({4'b0, pi} << 4) + {4'b0, pi} + 8'h55;  // i*17+0x55
    wire [7:0]  d_din = d1_v ? cbuf[t - 7'd40] : cbuf[t[3:0]];  // t-64 -> [3:0]

    // ---------------- DUTs ----------------------------------------------
    wire [31:0] pr_state;
    lfsr_prng u_prng (
        .clk(clk), .clk_en(dut_ce), .rst_n(rst_n),
        .seed_wr(sd_wr), .seed(PRNG_SEED), .step(pr_step), .state(pr_state));

    wire        s_ov;
    wire [7:0]  s_do;
    lfsr_scrambler u_scr (
        .clk(clk), .clk_en(dut_ce), .rst_n(rst_n),
        .seed_wr(sd_wr), .seed(SCR_SEED),
        .in_valid(scr_v), .din(pt_i),
        .out_valid(s_ov), .dout(s_do), .state_o());

    wire        d_ov;
    wire [7:0]  d_do;
    lfsr_descrambler u_dscr (
        .clk(clk), .clk_en(dut_ce), .rst_n(rst_n),
        .seed_wr(sd_wr || dseed2), .seed(sd_wr ? SCR_SEED : BAD_SEED),
        .in_valid(d1_v || d2_v), .din(d_din),
        .out_valid(d_ov), .dout(d_do), .state_o());

    // expected plaintext byte for collect index j (recomputed, no mult)
    wire [7:0] pt_j1 = ({4'b0, nd1[3:0]} << 4) + {4'b0, nd1[3:0]} + 8'h55;
    wire [7:0] pt_j2 = ({4'b0, nd2[3:0]} << 4) + {4'b0, nd2[3:0]} + 8'h55;

    // ---------------- control / digest ----------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running  <= 1'b0;
            done     <= 1'b0;
            pass     <= 1'b0;
            digest   <= 32'h811C9DC5;
            cycles   <= 16'd0;
            t        <= 7'd0;
            dg       <= 32'h811C9DC5;
            ok       <= 1'b1;
            nscr     <= 5'd0;
            nd1      <= 5'd0;
            nd2      <= 5'd0;
            dbg_data <= 32'd0;
            dbg_cnt  <= 3'd0;
        end else if (clk_en) begin
            dbg_cnt <= 3'd0;
            if (start && !running && !done) begin
                running <= 1'b1;
                cycles  <= 16'd0;
                t       <= 7'd0;
                dg      <= 32'h811C9DC5;
                ok      <= 1'b1;
                nscr    <= 5'd0;
                nd1     <= 5'd0;
                nd2     <= 5'd0;
            end else if (running && !done) begin
                cycles <= cycles + 16'd1;
                t      <= t + 7'd1;

                // fold PRNG state bytes (t=2..17, post-step states)
                if ((t >= 7'd2) && (t <= 7'd17)) begin
                    dg <= fnv(fnv(fnv(fnv(dg, pr_state[7:0]),
                        pr_state[15:8]), pr_state[23:16]), pr_state[31:24]);
                    dbg_data <= pr_state;
                    dbg_cnt  <= 3'd4;
                end

                // collect ciphertext (t=21..36)
                if (s_ov) begin
                    cbuf[nscr[3:0]] <= s_do;
                    dg       <= fnv(dg, s_do);
                    dbg_data <= {24'b0, s_do};
                    dbg_cnt  <= 3'd1;
                    nscr     <= nscr + 5'd1;
                end

                // collect descrambled pass1 (t=41..56) / pass2 (t=65..80)
                if (d_ov) begin
                    dg       <= fnv(dg, d_do);
                    dbg_data <= {24'b0, d_do};
                    dbg_cnt  <= 3'd1;
                    if (nd1 < 5'd16) begin
                        nd1 <= nd1 + 5'd1;
                        if (d_do !== pt_j1) ok <= 1'b0;
                    end else begin
                        nd2 <= nd2 + 5'd1;
                        if ((nd2 >= 5'd4) && (d_do !== pt_j2)) ok <= 1'b0;
                    end
                end

                if (nd2 == 5'd16) begin
                    done   <= 1'b1;
                    digest <= dg;
                    pass   <= (dg === EXP) && ok && (nscr == 5'd16) &&
                              (nd1 == 5'd16);
                end
            end
        end
    end
endmodule
