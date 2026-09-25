// Authored kernel. See ip/turbo_alpha_step/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_turbo_alpha_step (
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
reg signed [31:0] ta_sa, ta_sb, ta_cand, ta_other, ta_cur, ta_mx, ta_mn, ta_win;
reg [3:0] ta_sbit, ta_wbit, ta_tie, ta_clampc;
reg [15:0] ta_cnt;
reg ta_first;
wire ta_bad = (c[29:0] != 30'd0);
wire [255:0] ta_base = c[31] ? 256'd0 : state_r;
wire [3:0] ta_aprev = ta_base[35:32];
wire [3:0] ta_bprev = ta_base[39:36];
wire [15:0] ta_prevcnt = ta_base[111:96];
wire [31:0] ta_alpha = ta_base[31:0];
wire [31:0] ta_prevalpha = ta_base[87:56];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ta_sa=32'sd0; ta_sb=32'sd0; ta_cand=32'sd0; ta_other=32'sd0; ta_cur=32'sd0;
       ta_mx=-32'sd129; ta_mn=32'sd128; ta_win=32'sd0;
       ta_sbit=4'd0; ta_wbit=4'd0; ta_tie=4'd0; ta_clampc=4'd0; ta_cnt=16'd0;
       ta_first=1'b0; wide=0; wide2=0;
       if(ta_bad) f = 1'b1;
       else begin
           for(i=0; i<4; i=i+1) begin
               idx = (i >> 1) << 3;
               ta_sa = $signed({{24{ta_alpha[idx + 7]}}, ta_alpha[idx +: 8]});
               idx = ((i >> 1) + 2) << 3;
               ta_sb = $signed({{24{ta_alpha[idx + 7]}}, ta_alpha[idx +: 8]});
               idx = i << 3;
               ta_cand = ta_sa + $signed({{24{a[idx + 7]}}, a[idx +: 8]});
               ta_other = ta_sb + $signed({{24{b[idx + 7]}}, b[idx +: 8]});
               if(ta_cand < -32'sd128 || ta_cand > 32'sd127 ||
                  ta_other < -32'sd128 || ta_other > 32'sd127) begin
                   if(ta_clampc != 4'd15) ta_clampc = ta_clampc + 4'd1;
               end
               if(ta_cand > 32'sd127) ta_cand = 32'sd127;
               if(ta_cand < -32'sd128) ta_cand = -32'sd128;
               if(ta_other > 32'sd127) ta_other = 32'sd127;
               if(ta_other < -32'sd128) ta_other = -32'sd128;
               if(ta_cand > ta_other) begin
                   ta_sbit[i] = 1'b0;
                   ta_cur = ta_cand;
               end
               else begin
                   ta_sbit[i] = 1'b1;
                   ta_cur = ta_other;
                   if(ta_cand == ta_other) ta_tie[i] = 1'b1;
               end
               wide[(i << 3) +: 8] = ta_cur[7:0];
               if(ta_cur > ta_mx) ta_mx = ta_cur;
               if(ta_cur < ta_mn) ta_mn = ta_cur;
               ta_wbit[i] = ta_aprev[i];
           end
           ta_win = ta_mx - ta_mn;
           for(i=0; i<4; i=i+1) begin
               idx = i << 3;
               ta_cur = $signed({{24{wide[idx + 7]}}, wide[idx +: 8]});
               if(ta_win > 32'sd64) begin
                   ta_cur = ta_cur - (ta_win - 32'sd64);
                   if(ta_cur > 32'sd127) ta_cur = 32'sd127;
                   if(ta_cur < -32'sd128) ta_cur = -32'sd128;
                   if(ta_clampc != 4'd15) ta_clampc = ta_clampc + 4'd1;
               end
               else if(ta_win > 32'sd32) ta_cur = ta_cur - ta_mn;
               wide2[(i << 3) +: 8] = ta_cur[7:0];
           end
           ta_cnt = (ta_prevcnt == 16'hffff) ? 16'hffff : (ta_prevcnt + 16'd1);
           ta_first = (ta_prevcnt == 16'd0);
           r = c[30] ? wide[31:0] : wide2[31:0];
           x = {ta_win[7:0], 6'd0, ta_clampc, (ta_mx < 32'sd0), (ta_win > 32'sd64),
                (ta_win > 32'sd32), (|ta_tie), ta_first, c[31],
                {ta_wbit, ta_sbit}};
           state_n = {144'd0, ta_cnt, 8'd0, ta_alpha, 16'd0,
                      {ta_wbit, ta_sbit}, wide2[31:0]};
           f = (ta_prevcnt == 16'hffff);
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
