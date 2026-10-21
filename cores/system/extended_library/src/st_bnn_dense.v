// ============================================================================
// st_bnn_dense -- selftest cell for bnn_dense (idx36, TAG BDN).
//
// Deterministic schedule (clk_en beats after start):
//   t=0..3   : weight writes  w[n] = xs^n(seed)          (xorshift stream)
//   t=4..7   : bias writes    b[n] = signed6(s[5:0]) of the next 4 states
//   t=8..23  : stream in_vec  = next 16 xorshift states (1 vec/beat)
//   t=9..24  : out_valid beats -> fold byte {4'b0, out[3:0]}
// Internal check: exactly 16 output beats.
// EXP comes from tools/golden_acc.py only (trap T1).
// ============================================================================
module st_bnn_dense (
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

    localparam [31:0] EXP    = 32'h8792E554;  // golden_acc.py BDN
    localparam [31:0] XSEED  = 32'h9E3779B9;
    localparam        NVEC   = 16;
    localparam        NNEUR  = 4;

    // xorshift32 stimulus (shift/xor only -- no multipliers, T4)
    function [31:0] xs32;
        input [31:0] v;
        reg [31:0] t;
        begin
            t = v ^ (v << 13);
            t = t ^ (t >> 17);
            t = t ^ (t << 5);
            xs32 = t;
        end
    endfunction

    reg         running;
    reg  [5:0]  t;
    reg  [31:0] s;
    reg  [31:0] dg;
    reg         ok;
    reg  [5:0]  nout;
    reg  [31:0] dbg_data;
    reg  [2:0]  dbg_cnt;

    // drive signals (combinational from beat counter t: the DUT samples
    // them at the end of the same clk_en beat, so w[n]=s_n etc.)
    wire        w_en     = running && !done && (t < NNEUR);
    wire        b_en     = running && !done && (t >= NNEUR) && (t < 2*NNEUR);
    wire        in_valid = running && !done &&
                           (t >= 2*NNEUR) && (t < 2*NNEUR + NVEC);
    wire [1:0]  w_addr   = t[1:0];            // t=0..3  -> 0..3
    wire [1:0]  b_addr   = t[1:0];            // t=4..7  -> 0..3
    wire [31:0] w_data   = s;
    wire signed [7:0] b_data = {{2{s[5]}}, s[5:0]};   // signed6 -> signed8
    wire [31:0] in_vec   = s;

    wire        d_v;
    wire [3:0]  d_out;
    bnn_dense #(.NIN(32), .N(4)) u_dut (
        .clk(clk), .clk_en(clk_en && running || !rst_n), .rst_n(rst_n),
        .w_en(w_en), .w_addr(w_addr), .w_data(w_data),
        .b_en(b_en), .b_addr(b_addr), .b_data(b_data),
        .in_valid(in_valid), .in_vec(in_vec),
        .out_valid(d_v), .out(d_out));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running   <= 1'b0;
            done      <= 1'b0;
            pass      <= 1'b0;
            digest    <= 32'h811C9DC5;
            cycles    <= 16'd0;
            t         <= 6'd0;
            s         <= XSEED;
            dg        <= 32'h811C9DC5;
            ok        <= 1'b1;
            nout      <= 6'd0;
            dbg_data  <= 32'd0;
            dbg_cnt   <= 3'd0;
        end else if (clk_en) begin
            dbg_cnt <= 3'd0;
            if (start && !running && !done) begin
                running <= 1'b1;
                cycles  <= 16'd0;
                t       <= 6'd0;
                s       <= XSEED;
                dg      <= 32'h811C9DC5;
                ok      <= 1'b1;
                nout    <= 6'd0;
            end else if (running && !done) begin
                cycles <= cycles + 16'd1;
                t      <= t + 6'd1;
                // ---- stimulus: s advances once per beat while driving --
                if (t < 2*NNEUR + NVEC) s <= xs32(s);
                // ---- collect ----
                if (d_v) begin
                    dg       <= fnv(dg, {4'b0, d_out});
                    dbg_data <= {24'b0, 4'b0, d_out};
                    dbg_cnt  <= 3'd1;
                    nout     <= nout + 6'd1;
                end
                if (nout == NVEC[5:0]) begin
                    done   <= 1'b1;
                    digest <= dg;
                    pass   <= (dg === EXP) && ok;
                end
            end
        end
    end
endmodule
