// ============================================================================
// fft64: 64-point radix-2 DIT FFT, 16-bit signed complex, Q1.15 fixed point.
//
// Ordering: host writes 64 NATURAL-order input samples through ld_*; the core
// stores them bit-reversed internally. Output read back through rd_* is
// NATURAL order X[0..63].
//
// Scaling: every butterfly output is (u +/- t) >>> 1, so the result is
// DFT(x)/64 in Q1.15. Butterfly results wrap to signed 16 bits (deterministic
// truncation, matched by the golden model).
//
// 0-DSP twiddle multiply: W64^k = cos(2 pi k/64) - j sin(2 pi k/64) in Q1.15
// (cos0 saturated to 32767). Three signed 17-bit shift-add products use
// guarded pre-adds; low-32-bit recombination matches four 16-bit products.
// There is no multiplication operator in the datapath, so no DSP is inferred.
// t = b*W is rounded half-up: (p + 0x4000) >>> 15.
//
// Timing: one butterfly per 4 clk_en beats (RD_A, RD_B, WR_A, WR_B):
//   32 butterflies * 6 stages * 4 beats = 768 beats after start.
// ============================================================================
module fft64 #(
    parameter NSTAGE = 6           // diagnostic: run only NSTAGE stages
) (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    // load port (natural order in; ignored while busy)
    input  wire        ld_en,
    input  wire [5:0]  ld_addr,
    input  wire signed [15:0] ld_re,
    input  wire signed [15:0] ld_im,
    // run control
    input  wire        start,
    output reg         busy,
    output reg         done,
    // readout port (natural order out; valid 1 clk_en beat after rd_en)
    input  wire        rd_en,
    input  wire [5:0]  rd_addr,
    output wire signed [15:0] rd_re,
    output wire signed [15:0] rd_im
);

// Low 32 bits of signed 17x17 multiplication (no DSP). Guard bits on the
// pre-adds are necessary; final complex products preserve modulo-2^32 math.
function signed [31:0] mul17;
    input signed [16:0] a;
    input signed [16:0] b;
    reg signed [31:0] sa;
    reg signed [31:0] terms [0:31];
    integer i, span;
    begin
        sa  = a;
        for (i = 0; i < 32; i = i + 1) terms[i] = 32'sd0;
        for (i = 0; i < 16; i = i + 1)
            terms[i] = b[i] ? (sa <<< i) : 32'sd0;
        terms[16] = b[16] ? -(sa <<< 16) : 32'sd0;
        // Balanced reduction avoids sixteen dependent carry-propagate adds.
        for (span = 16; span > 0; span = span >> 1)
            for (i = 0; i < span; i = i + 1)
                terms[i] = terms[2*i] + terms[2*i+1];
        mul17 = terms[0];
    end
endfunction

localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_RDA  = 3'd1;
localparam [2:0] S_RDB  = 3'd2;
localparam [2:0] S_WRA  = 3'd3;
localparam [2:0] S_WRB  = 3'd4;

reg [2:0] st;
reg [2:0] stage;      // 1..6
reg [4:0] bf;         // butterfly index within stage, 0..31
reg signed [15:0] oj_re, oj_im;
reg signed [31:0] g0, g1, g2;

// butterfly geometry from (stage, bf)
wire [5:0] half   = 6'd1 << (stage - 3'd1);
wire [5:0] blk    = {1'b0, bf} >> (stage - 3'd1);
wire [5:0] pos    = {1'b0, bf} & (half - 6'd1);
wire [5:0] idx_i  = (blk << stage) | pos;
wire [5:0] idx_j  = idx_i + half;
wire [5:0] tw_idx = pos << (3'd6 - stage);

// RAM port mux: FSM owns while busy, host otherwise (mux is OUTSIDE the RAM
// module, keeping the T5-safe sdp_ram shape).
wire        fsm_re = (st == S_RDA) || (st == S_RDB);
// Fetch b/twiddle first, then a. Register products during the second read.
// This uses the existing four-beat schedule to split multiply from recombine.
wire [5:0]  fsm_raddr = (st == S_RDA) ? idx_j : idx_i;
wire        fsm_we = (st == S_WRA) || (st == S_WRB);
wire [5:0]  fsm_waddr = (st == S_WRA) ? idx_i : idx_j;

// q_* holds b during S_RDB, then a during S_WRA.
wire [17:0] q_re_w, q_im_w;
wire [17:0] twc_q, tws_q;
wire signed [15:0] b_re = q_re_w[15:0];
wire signed [15:0] b_im = q_im_w[15:0];
wire signed [15:0] a_re = q_re_w[15:0];
wire signed [15:0] a_im = q_im_w[15:0];
wire signed [15:0] tw_c = twc_q[15:0];
wire signed [15:0] tw_s = tws_q[15:0];

// Three-product complex multiply:
// g0=(re+im)*cos, g1=im*(sin-cos), g2=re*(cos+sin).
// re*cos+im*sin = g0+g1; im*cos-re*sin = g0-g2.
wire signed [16:0] b_sum = {b_re[15],b_re} + {b_im[15],b_im};
wire signed [16:0] sc_diff = {tw_s[15],tw_s} - {tw_c[15],tw_c};
wire signed [16:0] cs_sum = {tw_c[15],tw_c} + {tw_s[15],tw_s};
wire signed [31:0] g0_next = mul17(b_sum, {tw_c[15],tw_c});
wire signed [31:0] g1_next = mul17({b_im[15],b_im}, sc_diff);
wire signed [31:0] g2_next = mul17({b_re[15],b_re}, cs_sum);
wire signed [16:0] t_re = (g0 + g1 + 32'sh00004000) >>> 15;
wire signed [16:0] t_im = (g0 - g2 + 32'sh00004000) >>> 15;

wire signed [17:0] s_re = { {2{a_re[15]}}, a_re } + { {1{t_re[16]}}, t_re };
wire signed [17:0] s_im = { {2{a_im[15]}}, a_im } + { {1{t_im[16]}}, t_im };
wire signed [17:0] d_re = { {2{a_re[15]}}, a_re } - { {1{t_re[16]}}, t_re };
wire signed [17:0] d_im = { {2{a_im[15]}}, a_im } - { {1{t_im[16]}}, t_im };
wire signed [16:0] oi_re = s_re >>> 1;
wire signed [16:0] oi_im = s_im >>> 1;
wire signed [16:0] oj_re_w = d_re >>> 1;
wire signed [16:0] oj_im_w = d_im >>> 1;

wire [15:0] fsm_wdata_re = (st == S_WRA) ? oi_re[15:0] : oj_re;
wire [15:0] fsm_wdata_im = (st == S_WRA) ? oi_im[15:0] : oj_im;

wire [5:0] ld_waddr = {ld_addr[0], ld_addr[1], ld_addr[2],
                       ld_addr[3], ld_addr[4], ld_addr[5]};   // bit-reverse

wire        ram_we    = busy ? fsm_we    : ld_en;
wire [5:0]  ram_waddr = busy ? fsm_waddr : ld_waddr;
wire [15:0] ram_wdata_re = busy ? fsm_wdata_re : ld_re;
wire [15:0] ram_wdata_im = busy ? fsm_wdata_im : ld_im;
wire        ram_re    = busy ? fsm_re    : rd_en;
wire [5:0]  ram_raddr = busy ? fsm_raddr : rd_addr;

// REGS=1: reg-array storage -- the DPX9B read path is marginal on this
// silicon for the FFT's access pattern (see sig_sdp_ram.v note).
sig_sdp_ram #(.WIDTH(18), .DEPTH(64), .REGS(1)) ram_re_i (
    .clk(clk), .clk_en(clk_en),
    .we(ram_we), .waddr(ram_waddr), .wdata({2'b00, ram_wdata_re}),
    .re(ram_re), .raddr(ram_raddr), .q(q_re_w)
);
sig_sdp_ram #(.WIDTH(18), .DEPTH(64), .REGS(1)) ram_im_i (
    .clk(clk), .clk_en(clk_en),
    .we(ram_we), .waddr(ram_waddr), .wdata({2'b00, ram_wdata_im}),
    .re(ram_re), .raddr(ram_raddr), .q(q_im_w)
);

// twiddle ROMs (LUT case-tables; never inferred RAM -- see tw_rom_*.v),
// read during S_RDA -> valid from S_RDB onward
tw_rom_cos rom_cos (
    .clk(clk), .clk_en(clk_en), .re(st == S_RDA), .raddr(tw_idx[4:0]), .q(twc_q)
);
tw_rom_sin rom_sin (
    .clk(clk), .clk_en(clk_en), .re(st == S_RDA), .raddr(tw_idx[4:0]), .q(tws_q)
);

assign rd_re = q_re_w[15:0];
assign rd_im = q_im_w[15:0];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= S_IDLE; busy <= 1'b0; done <= 1'b0;
        stage <= 3'd1; bf <= 5'd0;
        g0 <= 32'sd0; g1 <= 32'sd0; g2 <= 32'sd0;
        oj_re <= 16'sd0; oj_im <= 16'sd0;
    end else if (clk_en) begin
        case (st)
            S_IDLE: begin
                if (start) begin
                    busy <= 1'b1; done <= 1'b0;
                    stage <= 3'd1; bf <= 5'd0;
                    st <= S_RDA;
                end
            end
            S_RDA: begin
                st <= S_RDB;
            end
            S_RDB: begin
                g0 <= g0_next;
                g1 <= g1_next;
                g2 <= g2_next;
                st <= S_WRA;
            end
            S_WRA: begin
                oj_re <= oj_re_w[15:0];     // hold (u - t) >>> 1 for S_WRB
                oj_im <= oj_im_w[15:0];
                st <= S_WRB;
            end
            S_WRB: begin
                if (bf == 5'd31) begin
                    bf <= 5'd0;
                    if (stage == NSTAGE[2:0]) begin
                        st <= S_IDLE; busy <= 1'b0; done <= 1'b1;
                    end else begin
                        stage <= stage + 3'd1;
                        st <= S_RDA;
                    end
                end else begin
                    bf <= bf + 5'd1;
                    st <= S_RDA;
                end
            end
            default: st <= S_IDLE;
        endcase
    end
end

endmodule
