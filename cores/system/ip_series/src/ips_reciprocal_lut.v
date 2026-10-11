`timescale 1ns / 1ps
// ips_reciprocal_lut : 12-bit reciprocal ROM with linear interpolation, one
// Newton-Raphson refinement step and an exact-division check flag.
//
// Contract, mirrored independently by models/ips_reciprocal_lut.py:
//   One operation is accepted on the enabled posedge where start && !busy.  That
//   beat only captures den into denr, so an operation takes 8 enabled beats:
//     S_IDLE(cap) S_ADDR S_ROM0 S_ROM1 S_MUL0 S_MUL1 S_MUL2 S_OUT.
//   valid pulses on the beat after S_OUT and the result registers hold until the
//   next operation publishes.  A start presented while busy is ignored and every
//   register is gated by clk_en (docs/IP_CORE_SOP.md trap T2).
//   Arithmetic, all unsigned, with dn the normalized denominator:
//     nsh = leading zeros of den, dn = (den << nsh) so bit FRAC-1 of dn is set,
//           i.e. dn is in [2**(FRAC-1), 2**FRAC - 1]; nsh = {c8,c4,c2,c1}.
//     ridx = dn[FRAC-2 -: IDXB], rwt = dn[WBITS-1:0], nflag = (nsh != 0).
//     v[i] = floor(2**(2*FRAC-1) / (2**(FRAC-1) + 2**(FRAC-1-IDXB) * i)) is a
//            9-entry case ROM (no block array, so nothing maps to a black-boxed
//            BSRAM whose OSS simulation model is empty, docs trap T5).
//     diff  = v[ridx] - v[ridx+1]
//     seed  = v[ridx] - BASE - ((diff * rwt) >> WBITS),  BASE  = 2**(FRAC-1)
//     r0    = 2*seed + UNIT,                             UNIT  = 2**FRAC
//     p12   = (dn * r0) >> FRAC
//     resid = (UNIT + UNIT) - p12          (the Newton-Raphson factor 2 - dn*r0)
//     recip = (r0 * resid) >> FRAC         (exactly one refinement step)
//     exact = (dn * r0 == EQ)              with EQ = 2**(2*FRAC): the seed
//            product is already exact, so 1/den terminates in this format and
//            recip == r0.
//   One 14x14 multiplier instance serves all three products through the
//   stage-selected operand muxes, which is how the core stays inside its single
//   DSP budget (docs/IP_CORE_SOP.md trap T4: no stray constant multiplies).
//   den == 0 is the undefined reciprocal: the pass sequence still runs on dn = 0
//   (a deterministic datapath), recip publishes the defined value 0, rnshift,
//   nflag and exact publish 0, r0/resid publish the dn = 0 datapath values, err
//   pulses for that operation and sticky latches the error for the rest of the
//   run.  err and sticky are folded into the digest by the testbench.
module ips_reciprocal_lut #(
    parameter FRAC  = 12,
    parameter IDXB  = 3,
    parameter WBITS = 8
)(
    input  wire             clk,
    input  wire             clk_en,
    input  wire             rst_n,

    input  wire             start,
    input  wire [FRAC-1:0]  den,
    output wire             busy,

    output reg  [FRAC+1:0]  recip,
    output reg  [FRAC+1:0]  r0,
    output reg  [FRAC+1:0]  resid,
    output wire [IDXB-1:0]  ridx,
    output wire [WBITS-1:0] rwt,
    output reg  [3:0]       rnshift,
    output reg              nflag,
    output reg              exact,
    output reg              err,
    output reg              sticky,
    output reg              valid,
    output reg  [7:0]       done,
    output reg  [3:0]       iter,
    output reg  [3:0]       stage
);

localparam [13:0] UNIT = 14'd4096;
localparam [13:0] BASE = 14'd2048;
localparam [27:0] EQ   = 28'd1 << (2 * FRAC);

localparam [3:0] S_IDLE = 4'd0;
localparam [3:0] S_ADDR = 4'd1;
localparam [3:0] S_ROM0 = 4'd2;
localparam [3:0] S_ROM1 = 4'd3;
localparam [3:0] S_MUL0 = 4'd4;
localparam [3:0] S_MUL1 = 4'd5;
localparam [3:0] S_MUL2 = 4'd6;
localparam [3:0] S_OUT  = 4'd7;

// ---------------------------------------------------------------------------
// leading-zero normalisation of the captured denominator
// ---------------------------------------------------------------------------
reg [FRAC-1:0] denr;
reg            abrt;

wire [FRAC-1:0] zero_v = {FRAC{1'b0}};
wire            zero   = (den == zero_v);

wire c8 = ~|denr[FRAC-1 -: 8];
wire [FRAC-1:0] v8 = c8 ? {denr[FRAC-9:0], 8'd0} : denr;
wire c4 = ~|v8[FRAC-1 -: 4];
wire [FRAC-1:0] v4 = c4 ? {v8[FRAC-5:0], 4'd0} : v8;
wire c2 = ~|v4[FRAC-1 -: 2];
wire [FRAC-1:0] v2 = c2 ? {v4[FRAC-3:0], 2'd0} : v4;
wire c1 = ~v2[FRAC-1];
wire [FRAC-1:0] dn = c1 ? {v2[FRAC-2:0], 1'd0} : v2;

wire [3:0] nsh = {c8, c4, c2, c1};

assign ridx = dn[FRAC-2 -: IDXB];
assign rwt  = dn[WBITS-1:0];
assign busy = (stage != S_IDLE);

// ---------------------------------------------------------------------------
// the 9-entry interpolation ROM: a case, so it maps to LUTs
// ---------------------------------------------------------------------------
reg [3:0] raddr;

function [13:0] rom14;
    input [3:0] a;
    begin
        case (a)
            4'd0:    rom14 = 14'd4096;
            4'd1:    rom14 = 14'd3640;
            4'd2:    rom14 = 14'd3276;
            4'd3:    rom14 = 14'd2978;
            4'd4:    rom14 = 14'd2730;
            4'd5:    rom14 = 14'd2520;
            4'd6:    rom14 = 14'd2340;
            4'd7:    rom14 = 14'd2184;
            4'd8:    rom14 = 14'd2048;
            default: rom14 = 14'd2048;
        endcase
    end
endfunction

wire [13:0] rom_q  = rom14(raddr);
wire [3:0]  idx4   = ridx;
wire [3:0]  nxt_ra = idx4 + 4'd1;

// ---------------------------------------------------------------------------
// one shared multiplier instance, three products
// ---------------------------------------------------------------------------
reg  [13:0] t0r;
reg  [13:0] diffr;
wire [13:0] dn_e   = dn;
wire [13:0] frac_e = rwt;

reg  [13:0] ma;
reg  [13:0] mb;

always @(*) begin
    case (stage)
        S_MUL0: begin ma = diffr; mb = frac_e; end
        S_MUL1: begin ma = dn_e;  mb = r0;     end
        S_MUL2: begin ma = r0;    mb = resid;  end
        default: begin ma = 14'd0; mb = 14'd0; end
    endcase
end

wire [27:0] mout  = ma * mb;
wire [13:0] iseed = t0r - BASE - (mout >> WBITS);
wire [13:0] ir0   = (iseed << 1) + UNIT;
wire [13:0] ip12  = mout >> FRAC;
wire [13:0] ires  = (UNIT + UNIT) - ip12;
wire        iex   = (mout == EQ);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        recip   <= 14'd0;
        r0      <= 14'd0;
        resid   <= 14'd0;
        rnshift <= 4'd0;
        nflag   <= 1'b0;
        exact   <= 1'b0;
        err     <= 1'b0;
        sticky  <= 1'b0;
        valid   <= 1'b0;
        done    <= 8'h00;
        iter    <= 4'd0;
        stage   <= S_IDLE;
        denr    <= {FRAC{1'b0}};
        abrt    <= 1'b0;
        raddr   <= 4'd0;
        t0r     <= 14'd0;
        diffr   <= 14'd0;
    end else if (clk_en) begin
        valid <= (stage == S_OUT);
        done  <= done + {7'd0, (stage == S_OUT)};
        iter  <= (stage == S_IDLE) ? 4'd0 : (iter + 4'd1);

        case (stage)
            S_IDLE: begin
                if (start) begin
                    denr   <= den;
                    abrt   <= zero;
                    sticky <= (sticky | zero);
                    stage  <= S_ADDR;
                end
            end
            S_ADDR: begin
                raddr <= idx4;
                stage <= S_ROM0;
            end
            S_ROM0: begin
                t0r   <= rom_q;
                raddr <= nxt_ra;
                stage <= S_ROM1;
            end
            S_ROM1: begin
                diffr <= (t0r - rom_q);
                stage <= S_MUL0;
            end
            S_MUL0: begin
                r0    <= ir0;
                stage <= S_MUL1;
            end
            S_MUL1: begin
                resid <= ires;
                exact <= iex;
                stage <= S_MUL2;
            end
            S_MUL2: begin
                recip <= (abrt ? 14'd0 : ip12);
                stage <= S_OUT;
            end
            S_OUT: begin
                rnshift <= (abrt ? 4'd0 : nsh);
                nflag   <= (!abrt) && (nsh != 4'd0);
                err     <= abrt;
                stage   <= S_IDLE;
            end
            default: begin
                stage <= S_IDLE;
            end
        endcase
    end
end

endmodule
