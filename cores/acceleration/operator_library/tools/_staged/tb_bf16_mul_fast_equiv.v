`timescale 1ns/1ps
// STAGED SCRATCH FILE -- equivalence evidence for tools/_staged/bf16_mul_fast.v.
// Three independent checks on every comparison:
//   A = rtl/acc_bf16_mul.v             (the release authored kernel, unmodified)
//   F = tools/_staged/bf16_mul_fast.v  (the shallow rewrite)
//   M = mdl_lane below, a behavioral model written straight from the
//       ip/bf16_mul/SPEC.md prose: decode both bf16 halves to
//       mantissa*2^(Eff-134) with Eff=max(E,1), form the exact 8x8 product, then
//       pick the nearest representable bfloat16 by round-to-nearest-even done
//       with integer divide/modulo (not the release's mask/half/guard compares),
//       falling back to the 2^-133 subnormal grid below the smallest normal and
//       saturating to infinity above the largest.
// Fields compared: result, aux, fault, out_valid, in_ready and the full 256-bit
// state register, plus the combinational cone (r/x/f, state_n) against M.
//
// Run: iverilog -g2012 -s tb_bf16_mul_fast_equiv -o /tmp/x.vvp \
//        rtl/acc_bf16_mul.v tools/_staged/bf16_mul_fast.v \
//        tools/_staged/tb_bf16_mul_fast_equiv.v
//      vvp /tmp/x.vvp            (add +quick for a short smoke run)
module tb_bf16_mul_fast_equiv;

reg clk = 0;
always #5 clk = ~clk;

reg rst_n = 0, clk_en = 0, in_valid = 0, out_ready = 0;
reg [31:0] a = 0, b = 0, c = 0;
wire in_ready_a, in_ready_f;
wire out_valid_a, out_valid_f, fault_a, fault_f;
wire [31:0] result_a, aux_a, result_f, aux_f;

acc_bf16_mul dut_a (
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .in_valid(in_valid), .in_ready(in_ready_a),
    .a(a), .b(b), .c(c),
    .out_valid(out_valid_a), .out_ready(out_ready),
    .result(result_a), .aux(aux_a), .fault(fault_a));

acc_bf16_mul_fast dut_f (
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .in_valid(in_valid), .in_ready(in_ready_f),
    .a(a), .b(b), .c(c),
    .out_valid(out_valid_f), .out_ready(out_ready),
    .result(result_f), .aux(aux_f), .fault(fault_f));

integer beats = 0;          // clocked interface comparisons
integer cones = 0;          // combinational cone comparisons
integer mism = 0;
integer mism_af = 0, mism_am = 0, mism_fm = 0, mism_state = 0, mism_hs = 0;
integer bad_rows = 0;
integer need_beats, need_cones;
integer lim_lane, lim_exp_set, lim_rand;

reg [31:0] m_r, m_x;
reg        m_f;

// ---------------------------------------------------------------- the model
// aux bit map from the SPEC prose:
//   [0]=lane0 infinity [1]=zero result [2]=inexact [3]=rounding incremented
//   [4]=subnormal-grid path, [5..9]=the same five for lane1, [15:10]=0,
//   [31:16]=lane0's 16-bit mantissa product.  fault=1 on a NaN operand or a
//   0*infinity pair, and then result=aux=0.
task mdl_lane;
    input  [15:0] x, y;
    output        bad;
    output [23:0] bp;
    output [15:0] pr;
    reg [7:0] ex, ey, exx, eyy;
    reg [6:0] fx, fy;
    reg [7:0] ax, ay;
    reg       sgn;
    integer prod, bl, se, d, nn, q, qpre, lo, half, fld, sig;
    reg inf, inex, inc, sgrid, zero;
    begin
        ex = x[14:7]; fx = x[6:0];
        ey = y[14:7]; fy = y[6:0];
        ax = (ex == 8'd0) ? {1'b0, fx} : {1'b1, fx};
        ay = (ey == 8'd0) ? {1'b0, fy} : {1'b1, fy};
        sgn = x[15] ^ y[15];
        pr = {8'd0, ax} * {8'd0, ay};
        bad = ((ex == 8'hff && fx != 7'd0) || (ey == 8'hff && fy != 7'd0) ||
               (ex == 8'hff && ay == 8'd0) || (ey == 8'hff && ax == 8'd0));
        inf = 1'b0; inex = 1'b0; inc = 1'b0; sgrid = 1'b0; zero = 1'b0;
        if (bad) begin
            bp = 24'd0;
        end else if (ex == 8'hff || ey == 8'hff) begin
            inf = 1'b1;                          // sign-XOR infinity
            bp = {inf, 1'b0, 1'b0, 1'b0, 1'b0, 3'd0, {sgn, 8'hff, 7'd0}};
        end else if (ax == 8'd0 || ay == 8'd0) begin
            zero = 1'b1;                         // signed zero
            bp = {1'b0, 1'b0, 1'b0, 1'b0, zero, 3'd0, {sgn, 8'd0, 7'd0}};
        end else begin
            prod = pr;
            exx = (ex == 8'd0) ? 8'd1 : ex;      // Eff = max(E,1)
            eyy = (ey == 8'd0) ? 8'd1 : ey;
            se = exx + eyy;                      // value = prod * 2^(se-268)
            bl = 0;
            for (nn = 0; nn < 16; nn = nn + 1)
                if (((prod >> nn) & 1) != 0) bl = nn + 1;
            if (se + bl <= 142) begin
                sgrid = 1'b1;                    // below the smallest normal
                d = se - 135;                    // units of 2^-133
                fld = 0;
            end else begin
                d = 8 - bl;                      // units of 2^(f0-134)
                fld = se + bl - 142;
            end
            // round prod*2^d to an integer: nearest, ties to even
            qpre = 0; q = 0; lo = 0; half = 0;
            if (d >= 0) begin
                qpre = prod << d;
                q = qpre;
            end else if (-d <= 30) begin
                nn = 1 << (-d);
                qpre = prod / nn;
                lo = prod % nn;
                half = nn >> 1;
                q = qpre;
                if (lo > half || (lo == half && (qpre % 2) == 1)) q = q + 1;
                inex = (lo != 0);
                inc = (q != qpre);
            end else begin
                inex = 1'b1;                     // far below half a grid step
            end
            zero = 1'b0;
            if (sgrid) begin
                if (q >= 128) begin fld = 1; sig = 128; end
                else begin
                    fld = 0; sig = q;
                    if (q == 0) zero = 1'b1;
                end
            end else begin
                if (q >= 256) begin fld = fld + 1; sig = 128; end
                else sig = q;
            end
            if (fld >= 255) begin
                inf = 1'b1; inex = 1'b1; sgrid = 1'b0; zero = 1'b0; sig = 0;
            end
            bp = {inf, inex, inc, sgrid, zero, 3'd0,
                  {sgn, fld[7:0], sig[6:0]}};
        end
    end
endtask

task mdl_top;
    input [31:0] xa, ya;
    reg bad0, bad1;
    reg [23:0] bp0, bp1;
    reg [15:0] pr0, pr1;
    begin
        mdl_lane(xa[15:0], ya[15:0], bad0, bp0, pr0);
        mdl_lane(xa[31:16], ya[31:16], bad1, bp1, pr1);
        if (bad0 || bad1) begin
            m_r = 32'd0; m_x = 32'd0; m_f = 1'b1;
        end else begin
            m_r = {bp1[15:0], bp0[15:0]};
            m_x = 32'd0;
            m_x[0] = bp0[23]; m_x[1] = bp0[19]; m_x[2] = bp0[22];
            m_x[3] = bp0[21]; m_x[4] = bp0[20];
            m_x[5] = bp1[23]; m_x[6] = bp1[19]; m_x[7] = bp1[22];
            m_x[8] = bp1[21]; m_x[9] = bp1[20];
            m_x[31:16] = pr0;
            m_f = 1'b0;
        end
    end
endtask

// ------------------------------------------------------------- the comparators
task note;
    input [319:0] what;
    begin
        mism = mism + 1;
        if (mism <= 24) begin
            $display("MISMATCH t=%0t %0s", $time, what);
            $display("   a=%h b=%h | A out r=%h x=%h f=%b ov=%b ir=%b st=%h",
                     a, b, result_a, aux_a, fault_a, out_valid_a, in_ready_a,
                     dut_a.state_r);
            $display("   a=%h b=%h | F out r=%h x=%h f=%b ov=%b ir=%b st=%h",
                     a, b, result_f, aux_f, fault_f, out_valid_f, in_ready_f,
                     dut_f.state_r);
            mdl_top(a, b);
            $display("   cone A r=%h x=%h f=%b | cone F r=%h x=%h f=%b | model r=%h x=%h f=%b",
                     dut_a.r, dut_a.x, dut_a.f, dut_f.r, dut_f.x, dut_f.f,
                     m_r, m_x, m_f);
        end
    end
endtask

task cmp_iface;
    begin
        beats = beats + 1;
        if (result_a !== result_f || aux_a !== aux_f || fault_a !== fault_f ||
            out_valid_a !== out_valid_f) begin
            mism_af = mism_af + 1;
            note("interface A vs F");
        end
        if (in_ready_a !== in_ready_f) begin
            mism_hs = mism_hs + 1;
            note("in_ready A vs F");
        end
        if (dut_a.state_r !== dut_f.state_r ||
            dut_a.state_n !== dut_f.state_n) begin
            mism_state = mism_state + 1;
            note("256-bit state A vs F");
        end
    end
endtask

task cmp_cone;
    begin
        cones = cones + 1;
        mdl_top(a, b);
        if (dut_a.r !== dut_f.r || dut_a.x !== dut_f.x || dut_a.f !== dut_f.f) begin
            mism_af = mism_af + 1;
            note("cone A vs F");
        end
        if (dut_a.r !== m_r || dut_a.x !== m_x || dut_a.f !== m_f) begin
            mism_am = mism_am + 1;
            note("model vs A");
        end
        if (dut_f.r !== m_r || dut_f.x !== m_x || dut_f.f !== m_f) begin
            mism_fm = mism_fm + 1;
            note("model vs F");
        end
    end
endtask

// ---------------------------------------------------------------- stimulus gen
integer rng = 32'h250ACCE5;
function [31:0] nextrnd;
    begin
        rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
        nextrnd = rng;
    end
endfunction

// exponent and fraction values that sit on a branch boundary of the network
reg [7:0] eband [0:17];
reg [6:0] fband [0:11];
initial begin
    eband[0]=8'd0;   eband[1]=8'd1;   eband[2]=8'd2;   eband[3]=8'd3;
    eband[4]=8'd63;  eband[5]=8'd64;  eband[6]=8'd117; eband[7]=8'd118;
    eband[8]=8'd125; eband[9]=8'd126; eband[10]=8'd127;eband[11]=8'd128;
    eband[12]=8'd133;eband[13]=8'd134;eband[14]=8'd139;eband[15]=8'd140;
    eband[16]=8'd190;eband[17]=8'd254;
    fband[0]=7'd0;   fband[1]=7'd1;   fband[2]=7'd2;   fband[3]=7'd31;
    fband[4]=7'd63;  fband[5]=7'd64;  fband[6]=7'd65;  fband[7]=7'd96;
    fband[8]=7'd112; fband[9]=7'd125; fband[10]=7'd126;fband[11]=7'd127;
end

task rand_lane;
    output [15:0] v;
    reg [7:0] e;
    reg [6:0] f;
    reg       sg;
    begin
        sg = nextrnd() & 1;
        e  = eband[nextrnd() % 18];
        f  = fband[nextrnd() % 12];
        v  = {sg, e, f};
    end
endtask

task rand_lane_mix;
    output [15:0] v;
    reg [15:0] rv;
    begin
        rv = nextrnd();
        if (nextrnd() & 1) rand_lane(v);
        else if (rv[3]) v = {rv[15], eband[rv[11:4] % 18], rv[6:0]};
        else v = rv[15:0];
    end
endtask

localparam NVEC = 320;
reg [160:0] vec [0:NVEC-1];

// ------------------------------------------------------------------ phase 1
// The real release vector image with the strict all-enabled protocol.
task phase_vectors;
    integer sent, received;
    begin
        $readmemh("vectors/bf16_mul.mem", vec);
        rst_n = 0; clk_en = 0; in_valid = 0; out_ready = 0;
        a = 0; b = 0; c = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        sent = 0; received = 0;
        while (received < NVEC && sent + NVEC < 4 * NVEC) begin
            @(negedge clk);
            clk_en = 1; out_ready = 1;
            in_valid = (sent < NVEC);
            if (sent < NVEC) {a, b, c} = vec[sent][160:65];
            #1;                             // let both cones settle before compare
            cmp_cone;
            @(posedge clk);
            cmp_iface;
            if (clk_en && out_valid_a && out_ready) begin
                mdl_top(a, b);
                if ({result_a, aux_a, fault_a} !== vec[received][64:0]) begin
                    bad_rows = bad_rows + 1;
                    mism = mism + 1;
                    $display("VECTOR ROW %0d rtl={%h,%h,%b} file=%h model={%h,%h,%b}",
                             received, result_a, aux_a, fault_a,
                             vec[received][64:0], m_r, m_x, m_f);
                end
                if (m_f !== fault_a || m_r !== result_a || m_x !== aux_a) begin
                    mism_am = mism_am + 1;
                    note("retire model vs A (vector row)");
                end
                received = received + 1;
            end
            if (clk_en && in_valid && in_ready_a) sent = sent + 1;
        end
        if (received != NVEC) begin
            mism = mism + 1;
            $display("VECTOR STREAM STUCK sent=%0d received=%0d", sent, received);
        end
    end
endtask

// ------------------------------------------------------------------ phase 2
// Pure combinational sweeps.  The cone depends only on a and b, so both lanes
// are covered per drive by placing (x,y) in lane0 and (y,x) in lane1.
task sweep_pair;
    input [15:0] x, y;
    begin
        a = {y, x};
        b = {x, y};
        #1;
        cmp_cone;
    end
endtask

task phase_sweeps;
    integer i, j, k;
    reg [15:0] yv;
    reg [15:0] xv, wv;
    begin
        rst_n = 1; clk_en = 1; in_valid = 0; out_ready = 1; c = 0;
        #1;
        // every 16-bit pattern in one lane against a boundary set in the other
        for (j = 0; j < 12; j = j + 1) begin
            case (j)
                0:  yv = 16'h3f80;              //  1.0
                1:  yv = 16'h8000;              // -0.0
                2:  yv = 16'h0001;              // least subnormal
                3:  yv = 16'h007f;              // greatest subnormal
                4:  yv = 16'h3f00;              // least normal
                5:  yv = 16'h7f7f;              // greatest finite
                6:  yv = 16'h7f80;              // +infinity
                7:  yv = 16'h7fc0;              // NaN
                8:  yv = 16'hbf80;              // -1.0
                9:  yv = 16'h0040;              // half of the subnormal grid
                10: yv = 16'h3800;              // 2^-15
                default: yv = 16'h4248;         // 12.5
            endcase
            for (i = 0; i < lim_lane; i = i + 1) sweep_pair(i[15:0], yv);
        end
        // every exponent pair against boundary fraction sets
        for (i = 0; i < 256; i = i + 1) begin
            for (j = 0; j < 256; j = j + 1) begin
                for (k = 0; k < lim_exp_set; k = k + 1) begin
                    sweep_pair({1'b0, i[7:0], fband[k]},
                               {1'b1, j[7:0], fband[(k + 5) % 12]});
                    sweep_pair({1'b1, i[7:0], fband[11 - k]},
                               {1'b0, j[7:0], fband[(k + 3) % 12]});
                end
            end
        end
        // wide random 32-bit pairs
        for (i = 0; i < lim_rand; i = i + 1) begin
            a = nextrnd(); b = nextrnd(); c = nextrnd();
            #1; cmp_cone;
        end
        // boundary-biased random pairs, both lanes
        for (i = 0; i < lim_rand; i = i + 1) begin
            rand_lane_mix(xv); rand_lane_mix(wv);
            a = {wv, xv}; b = {xv, wv}; c = nextrnd();
            #1; cmp_cone;
        end
    end
endtask

// ------------------------------------------------------------------ phase 3
// Protocol stress: restart (c[31]=1), holds (clk_en=0), backpressure
// (out_ready=0), valid gaps, and async reset while a response is pending.
task phase_protocol;
    integer i;
    reg [15:0] xv, wv;
    begin
        rst_n = 0; clk_en = 0; in_valid = 0; out_ready = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        for (i = 0; i < 60000; i = i + 1) begin
            @(negedge clk);
            clk_en    = (nextrnd() & 3) != 0;
            out_ready = (nextrnd() & 7) != 0;
            in_valid  = (nextrnd() & 3) != 0;
            rand_lane_mix(xv); rand_lane_mix(wv);
            a = {wv, xv}; b = {xv, wv}; c = nextrnd();
            if ((i % 97) == 0) c[31] = 1'b1;         // restart strobe
            #1;                             // let both cones settle before compare
            cmp_cone;
            @(posedge clk);
            cmp_iface;
            if ((i % 401) == 0) begin                // async reset mid-stream
                @(negedge clk); clk_en = 0; rst_n = 0;
                repeat (2) @(posedge clk);
                @(negedge clk); rst_n = 1;
                cmp_iface;
            end
        end
        @(negedge clk); in_valid = 0; clk_en = 1; out_ready = 1;
        repeat (6) @(posedge clk);
        cmp_iface;
    end
endtask

initial begin
    if ($test$plusargs("quick")) begin
        lim_lane = 1024; lim_exp_set = 1; lim_rand = 4000;
        need_beats = 20000; need_cones = 20000;
    end else begin
        lim_lane = 65536; lim_exp_set = 4; lim_rand = 150000;
        need_beats = 60000; need_cones = 1000000;
    end
    $display("bf16_mul equivalence A=release F=staged M=spec-model quick=%b",
             $test$plusargs("quick"));
    phase_vectors;
    $display("phase1 vectors beats=%0d cones=%0d mismatches=%0d",
             beats, cones, mism);
    phase_sweeps;
    $display("phase2 sweeps  beats=%0d cones=%0d mismatches=%0d",
             beats, cones, mism);
    phase_protocol;
    $display("phase3 protocol beats=%0d cones=%0d mismatches=%0d",
             beats, cones, mism);
    $display("detail A_vs_F=%0d model_vs_A=%0d model_vs_F=%0d state=%0d handshake=%0d vector_rows_bad=%0d",
             mism_af, mism_am, mism_fm, mism_state, mism_hs, bad_rows);
    if (mism != 0)
        $display("EQUIV FAIL mismatches=%0d beats=%0d cones=%0d",
                 mism, beats, cones);
    else if (beats < need_beats || cones < need_cones)
        $display("EQUIV FAIL(coverage) mismatches=0 beats=%0d cones=%0d",
                 beats, cones);
    else
        $display("EQUIV PASS mismatches=0 beats=%0d cones=%0d", beats, cones);
    $finish;
end
endmodule
