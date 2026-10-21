// Authored kernel. See ip/convk7_acs16/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_convk7_acs16 (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [255:0] state_r, state_n;
reg [31:0] r, x, temp, mask, pa, pb, pc, ph, pl;
reg [32:0] ext;
reg [63:0] wide, wide2;
reg signed [63:0] swide, swide2;
reg signed [31:0] sa, sb, sc;
reg [95:0] data;
reg f;
integer i, j, idx, lane, sh;
// The kernel sign-extends a branch-metric byte held in the 32-bit template
// temporaries temp/mask. Those registers keep the zero-extended byte, so the
// sign fill must cover only the byte itself ({{24{temp[7]}}, temp[7:0]} = 32
// bits); filling over the whole register makes a 56-bit vector and turns every
// negative delta into about -2^32, which saturates every candidate to zero.
reg [7:0] acs_m0, acs_m1, acs_c0, acs_c1, acs_best, acs_min, acs_max, acs_tmp;
reg [15:0] acs_surv, acs_cnt;
reg [3:0] acs_minlanes;
reg [7:0] acs_inc;
reg acs_tie, acs_clamp;
reg [127:0] acs_ns;
wire acs_bad = (c[29:0] != 30'd0);
wire [255:0] acs_base = c[31] ? 256'd0 : state_r;
wire [127:0] acs_metrics = acs_base[127:0];
wire [15:0] acs_prevcnt = acs_base[159:144];
wire acs_hist0 = acs_base[192];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    acs_m0=8'd0; acs_m1=8'd0; acs_c0=8'd0; acs_c1=8'd0; acs_best=8'd0;
       acs_min=8'd255; acs_max=8'd0; acs_tmp=8'd0; acs_surv=16'd0; acs_cnt=16'd0;
       acs_minlanes=4'd0; acs_inc=8'd0; acs_tie=1'b0; acs_clamp=1'b0;
       acs_ns=128'd0; wide=0; wide2=0;
       if(acs_bad) f = 1'b1;
       else begin
           for(j=0; j<16; j=j+1) begin
               idx = (j >> 1) << 3;
               acs_m0 = acs_metrics[idx +: 8];
               idx = ((j >> 1) + 8) << 3;
               acs_m1 = acs_metrics[idx +: 8];
               sh = (j & 3) << 3;
               temp = a[sh +: 8];
               mask = b[sh +: 8];
               swide = $signed({{24{temp[7]}}, temp[7:0]}) + $signed({24'd0, acs_m0});
               if(swide < 64'sd0) begin acs_c0 = 8'd0; acs_clamp = 1'b1; end
               else if(swide > 64'sd255) begin acs_c0 = 8'd255; acs_clamp = 1'b1; end
               else acs_c0 = swide[7:0];
               swide2 = $signed({{24{mask[7]}}, mask[7:0]}) + $signed({24'd0, acs_m1});
               if(swide2 < 64'sd0) begin acs_c1 = 8'd0; acs_clamp = 1'b1; end
               else if(swide2 > 64'sd255) begin acs_c1 = 8'd255; acs_clamp = 1'b1; end
               else acs_c1 = swide2[7:0];
               if(acs_c1 > acs_c0) begin
                   acs_best = acs_c1;
                   acs_surv[j] = 1'b1;
               end
               else begin
                   acs_best = acs_c0;
                   if(acs_c0 == acs_c1) acs_tie = 1'b1;
               end
               if(j < 8) wide[(j << 3) +: 8] = acs_best;
               else wide2[((j - 8) << 3) +: 8] = acs_best;
               if(acs_best < acs_min) acs_min = acs_best;
               if(acs_best > acs_max) acs_max = acs_best;
           end
           for(j=0; j<16; j=j+1) begin
               if(j < 8) acs_best = wide[(j << 3) +: 8];
               else acs_best = wide2[((j - 8) << 3) +: 8];
               if(acs_best == acs_min && acs_minlanes != 4'd15)
                   acs_minlanes = acs_minlanes + 4'd1;
               if(c[30]) acs_tmp = acs_best;
               else acs_tmp = acs_best - acs_min;
               acs_ns[(j << 3) +: 8] = acs_tmp;
               if(acs_tmp > acs_metrics[(j << 3) +: 8] && acs_inc != 8'd16)
                   acs_inc = acs_inc + 8'd1;
           end
           acs_cnt = (acs_prevcnt == 16'hffff) ? 16'hffff
                                               : (acs_prevcnt + 16'd1);
           r = {5'd0, acs_tie, acs_clamp, (!c[30]), (acs_max - acs_min),
                acs_max, acs_min};
           x = {acs_inc, acs_minlanes, (acs_prevcnt == 16'hffff),
                ((acs_max - acs_min) > 8'd127), (!acs_hist0), c[31],
                acs_surv[15:8], acs_surv[7:0]};
           state_n = {63'd0, 1'b1, r, acs_cnt, acs_surv, acs_ns};
           f = acs_clamp || (acs_prevcnt == 16'hffff);
       end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f; state_r<=state_n;
            end
        end
    end
end
endmodule
