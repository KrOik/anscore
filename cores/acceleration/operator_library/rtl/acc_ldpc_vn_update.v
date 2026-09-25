// Authored kernel. See ip/ldpc_vn_update/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ldpc_vn_update (
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
reg signed [31:0] vn_old, vn_msg, vn_sum;
reg [7:0] vn_byte;
reg [3:0] vn_clamp, vn_satm, vn_zero, vn_dec;
reg [3:0] vn_hard;
reg [15:0] vn_cnt;
reg vn_cntsat;
wire vn_bad = (c[30:0] != 30'd0);
wire [255:0] vn_base = c[31] ? 256'd0 : state_r;
wire [15:0] vn_prevcnt = vn_base[79:64];
wire vn_seeded = vn_base[81];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    vn_old=32'sd0; vn_msg=32'sd0; vn_sum=32'sd0; vn_byte=8'd0;
       vn_clamp=4'd0; vn_satm=4'd0; vn_zero=4'd0; vn_dec=4'd0; vn_hard=4'd0;
       vn_cnt=16'd0; vn_cntsat=1'b0;
       if(vn_bad) f = 1'b1;
       else begin
           state_n = vn_base;
           for(lane=0; lane<4; lane=lane+1) begin
               sh = lane << 3;
               vn_byte = a[sh +: 8];
               vn_msg = $signed({{24{vn_byte[7]}}, vn_byte});
               if(c[31]) begin
                   vn_byte = b[sh +: 8];
                   vn_old = $signed({{24{vn_byte[7]}}, vn_byte});
               end
               else vn_old = $signed({{16{vn_base[(lane << 4) + 15]}},
                                      vn_base[(lane << 4) +: 16]});
               vn_sum = vn_old + vn_msg;
               if(vn_sum > 32'sd32767) begin
                   vn_sum = 32'sd32767;
                   vn_satm = vn_satm | (4'b1 << lane);
               end
               else if(vn_sum < -32'sd32768) begin
                   vn_sum = -32'sd32768;
                   vn_satm = vn_satm | (4'b1 << lane);
               end
               if(vn_sum > 0) vn_hard = vn_hard | (4'b1 << lane);
               if(vn_sum == 0) vn_zero = vn_zero | (4'b1 << lane);
               pl = vn_sum[31] ? ($unsigned(32'd0) - $unsigned(vn_sum))
                               : $unsigned(vn_sum);
               pc = vn_old[31] ? ($unsigned(32'd0) - $unsigned(vn_old))
                               : $unsigned(vn_old);
               if(pl < pc) vn_dec = vn_dec | (4'b1 << lane);
               vn_byte = 8'h7f;
               if(vn_sum > 32'sd127) begin
                   vn_byte = 8'h7f;
                   vn_clamp = vn_clamp | (4'b1 << lane);
               end
               else if(vn_sum < -32'sd127) begin
                   vn_byte = 8'h81;
                   vn_clamp = vn_clamp | (4'b1 << lane);
               end
               else vn_byte = vn_sum[7:0];
               r = r | ({24'd0, vn_byte} << sh);
               state_n[(lane << 4) +: 16] = vn_sum[15:0];
           end
           vn_cnt = (vn_prevcnt == 16'hffff) ? 16'hffff
                                             : (vn_prevcnt + 16'd4);
           vn_cntsat = vn_base[80] || (vn_prevcnt == 16'hffff);
           x = {vn_cnt[3:0], (vn_hard == 4'b1111), vn_cntsat,
                (!vn_seeded && !c[31]), c[31], (~vn_zero), vn_hard, vn_dec,
                vn_zero, vn_satm, vn_clamp};
           state_n[95:64] = {14'd0, (vn_seeded || c[31]), vn_cntsat, vn_cnt};
           state_n[127:96] = a;
           state_n[159:128] = r;
           f = (|vn_satm) || (vn_prevcnt == 16'hffff);
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
