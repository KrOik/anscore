// ============================================================================
// otsu_thresh: Otsu threshold over a 256-bin 16-bit histogram.
//
// Histogram source is external: core drives h_addr (and h_req strobe); host
// must present h_data = hist[h_addr] one clk_en beat later (sync-read style,
// directly compatible with hist256 rd_en/rd_addr/rd_data).
//
// Algorithm (bit-exact vs tools/golden_model.py):
//   pass1: N = sum h, sumT = sum t*h
//   pass2 per t: w0 += h[t]; s0 += t*h[t]; w1 = N-w0
//     den = w0*w1; num = |s0*N - sumT*w0|
//     score = den==0||num==0 ? 0 : min(((num^2)>>32)/den, 0xFFFFFFFF)
//     argmax: first t with score > best.
// All multiplies/divides are sequential shift-add bit engines -> 0 DSP.
// Runs many beats (~<100k clk_en beats for two passes); full-rate safe: the
// per-beat logic is a single add/compare (no deep combinational chains).
// ============================================================================
module otsu_thresh (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         busy,
    output reg         done,
    output reg         h_req,
    output reg  [7:0]  h_addr,
    input  wire [15:0] h_data,
    output reg  [7:0]  thr,
    output reg  [31:0] best_score
);

// t*h : 8x16 -> 24 shift-add (t <= 255), small combinational helper
function [23:0] th8;
    input [7:0]  t;
    input [15:0] h;
    reg [23:0] a;
    integer k;
    begin
        a = 24'd0;
        for (k = 0; k < 8; k = k + 1)
            if (t[k]) a = a + ({8'd0, h} << k);
        th8 = a;
    end
endfunction

localparam [4:0] O_IDLE  = 5'd0;
localparam [4:0] O_P1A   = 5'd1;
localparam [4:0] O_P1B   = 5'd2;
localparam [4:0] O_P2I   = 5'd3;
localparam [4:0] O_P2A   = 5'd4;
localparam [4:0] O_P2B   = 5'd5;
localparam [4:0] O_MUL   = 5'd6;
localparam [4:0] O_DENCK = 5'd7;
localparam [4:0] O_P1CK  = 5'd8;
localparam [4:0] O_P2CK  = 5'd9;
localparam [4:0] O_NUMCK = 5'd10;
localparam [4:0] O_SQCK  = 5'd11;
localparam [4:0] O_DIV   = 5'd12;
localparam [4:0] O_CMP   = 5'd13;
localparam [4:0] O_FIN   = 5'd14;

reg [4:0]  st;
reg [7:0]  t;
reg [23:0] nsum;        // N  (< 2^24)
reg [39:0] sumT;        // sum t*h (< 2^32)
reg [23:0] w0;
reg [39:0] s0;
reg [63:0] p1r;
reg [63:0] num;
reg [63:0] den;
reg [31:0] score;
reg [31:0] best;
// sequential multiply engine: mAcc += mA<<i for set bits of mB, 1 bit/beat
// (mA is 128b: it shifts left up to 63 times, products reach 2^112)
reg [127:0] mA;
reg [63:0]  mB;
reg [127:0] mAcc;
reg [4:0]   mret;
// sequential restoring divider: dshr(96b) / den -> quo(96b), 1 bit/beat
reg [95:0]  dshr;
reg [48:0]  rem;
reg [95:0]  quo;
reg [6:0]   dcnt;

wire [48:0] rem2  = {rem[47:0], dshr[95]};
wire        divge = (rem2 >= {1'b0, den[47:0]});
wire [95:0] quo_n = {quo[94:0], divge};

wire [23:0] w0n = w0 + {8'd0, h_data};
wire [39:0] s0n = s0 + {16'd0, th8(t, h_data)};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= O_IDLE; busy <= 1'b0; done <= 1'b0; h_req <= 1'b0;
        h_addr <= 8'd0; thr <= 8'd0; best_score <= 32'd0;
        t <= 8'd0; nsum <= 24'd0; sumT <= 40'd0;
        w0 <= 24'd0; s0 <= 40'd0; p1r <= 64'd0; num <= 64'd0;
        den <= 64'd0; score <= 32'd0; best <= 32'd0;
        mA <= 128'd0; mB <= 64'd0; mAcc <= 128'd0; mret <= O_IDLE;
        dshr <= 96'd0; rem <= 49'd0; quo <= 96'd0; dcnt <= 7'd0;
    end else if (clk_en) begin
        h_req <= 1'b0;
        case (st)
            O_IDLE: begin
                if (start) begin
                    busy <= 1'b1; done <= 1'b0;
                    t <= 8'd0; nsum <= 24'd0; sumT <= 40'd0;
                    st <= O_P1A;
                end
            end
            // ---- pass 1: N, sumT ----
            O_P1A: begin
                h_addr <= t; h_req <= 1'b1; st <= O_P1B;
            end
            O_P1B: begin
                nsum <= nsum + {8'd0, h_data};
                sumT <= sumT + {16'd0, th8(t, h_data)};
                if (t == 8'd255) st <= O_P2I;
                else begin t <= t + 8'd1; st <= O_P1A; end
            end
            O_P2I: begin
                t <= 8'd0; w0 <= 24'd0; s0 <= 40'd0;
                best <= 32'd0; thr <= 8'd0;
                st <= O_P2A;
            end
            // ---- pass 2: cumulative sums + score per t ----
            O_P2A: begin
                h_addr <= t; h_req <= 1'b1; st <= O_P2B;
            end
            O_P2B: begin
                w0 <= w0n; s0 <= s0n;
                // den = w0n * (N - w0n)
                mA <= {104'd0, w0n};
                mB <= {40'd0, (nsum - w0n)};
                mAcc <= 128'd0; mret <= O_DENCK; st <= O_MUL;
            end
            // ---- shared sequential multiply (early exit when mB==0) ----
            O_MUL: begin
                if (mB == 64'd0) begin
                    st <= mret;
                end else begin
                    if (mB[0]) mAcc <= mAcc + mA;
                    mA <= mA << 1;
                    mB <= mB >> 1;
                end
            end
            O_DENCK: begin
                den <= mAcc[63:0];
                if (mAcc == 128'd0) begin
                    score <= 32'd0; st <= O_CMP;
                end else begin
                    mA <= {88'd0, s0};          // p1 = s0 * N
                    mB <= {40'd0, nsum};
                    mAcc <= 128'd0; mret <= O_P1CK; st <= O_MUL;
                end
            end
            O_P1CK: begin
                p1r <= mAcc[63:0];
                mA <= {88'd0, sumT};            // p2 = sumT * w0
                mB <= {40'd0, w0};
                mAcc <= 128'd0; mret <= O_P2CK; st <= O_MUL;
            end
            O_P2CK: begin
                num <= (p1r >= mAcc[63:0]) ? (p1r - mAcc[63:0])
                                           : (mAcc[63:0] - p1r);
                st <= O_NUMCK;
            end
            O_NUMCK: begin
                if (num == 64'd0) begin
                    score <= 32'd0; st <= O_CMP;
                end else begin
                    mA <= {64'd0, num}; mB <= num;   // num^2
                    mAcc <= 128'd0; mret <= O_SQCK; st <= O_MUL;
                end
            end
            O_SQCK: begin
                dshr <= mAcc[127:32];           // dividend = num^2 >> 32
                rem <= 49'd0; quo <= 96'd0; dcnt <= 7'd96;
                st <= O_DIV;
            end
            O_DIV: begin
                rem  <= divge ? (rem2 - {1'b0, den[47:0]}) : rem2;
                quo  <= quo_n;
                dshr <= {dshr[94:0], 1'b0};
                if (dcnt == 7'd1) begin
                    score <= (|quo_n[95:32]) ? 32'hFFFFFFFF : quo_n[31:0];
                    st <= O_CMP;
                end else begin
                    dcnt <= dcnt - 7'd1;
                end
            end
            O_CMP: begin
                if (score > best) begin
                    best <= score; thr <= t;
                end
                if (t == 8'd255) st <= O_FIN;
                else begin t <= t + 8'd1; st <= O_P2A; end
            end
            O_FIN: begin
                busy <= 1'b0; done <= 1'b1;
                best_score <= best;
                st <= O_IDLE;
            end
            default: st <= O_IDLE;
        endcase
    end
end

endmodule
