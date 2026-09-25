// Authored kernel. See ip/rs255_syndrome_acc/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_rs255_syndrome_acc (
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
function [7:0] rs_xt;                    // multiply by alpha = x, mod 0x11D
    input [7:0] v;
    begin
        rs_xt = {v[6:0], 1'b0} ^ (v[7] ? 8'h1D : 8'h00);
    end
endfunction

reg [31:0] rs_sy, rs_prevblk;
reg [3:0] rs_nz, rs_mask;
reg [15:0] rs_cnt;
reg rs_sticky, rs_partial, rs_clean;
wire [2:0] rs_count = b[2:0];
wire rs_bad = (b[31:3] != 29'd0) || (rs_count > 3'd4) || (c[30:0] != 30'd0);
wire [255:0] rs_base = c[31] ? 256'd0 : state_r;
wire [31:0] rs_old = rs_base[31:0];
wire [15:0] rs_prevcnt = rs_base[47:32];
wire rs_sticky0 = rs_base[48];
wire [31:0] rs_lastblk = c[31] ? state_r[31:0] : rs_base[127:96];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    rs_sy=32'd0; rs_prevblk=32'd0; rs_nz=4'd0; rs_mask=4'd0; rs_cnt=16'd0;
       rs_sticky=1'b0; rs_partial=1'b0; rs_clean=1'b0;
       if(rs_bad) f = 1'b1;
       else begin
           rs_sy = rs_old;
           for(j=0; j<4; j=j+1) begin
               if(j < rs_count) begin
                   idx = (j + 8) << 3;
                   temp = data[idx +: 8];
                   for(i=0; i<4; i=i+1) begin
                       ph = rs_sy[(i << 3) +: 8];
                       for(lane=0; lane<i; lane=lane+1) ph = rs_xt(ph);
                       rs_sy[(i << 3) +: 8] = ph ^ temp;
                   end
               end
           end
           for(i=0; i<4; i=i+1) begin
               mask = rs_sy[(i << 3) +: 8];
               if(mask != 32'd0) begin
                   rs_mask = rs_mask | (4'b1 << i);
                   rs_nz = rs_nz + 4'd1;
               end
           end
           rs_cnt = (rs_prevcnt == 16'hffff) ? 16'hffff
                    : (rs_prevcnt + {13'd0, rs_count});
           rs_sticky = rs_sticky0 || (rs_mask != 4'd0);
           rs_clean = (rs_sy == 32'd0);
           r = rs_sy;
           x = 32'd0;
           x[3:0] = rs_mask;
           x[6:4] = rs_nz;
           x[7] = rs_clean;
           x[8] = rs_sticky;
           x[9] = c[31];
           x[10] = (rs_lastblk == 32'd0);
           x[11] = (rs_count < 3'd4);
           x[12] = (rs_prevcnt == 16'hffff);
           x[15:13] = 3'd0;
           x[31:16] = rs_cnt;
           state_n = {128'd0, rs_lastblk, a,
                      {15'd0, rs_sticky, rs_cnt}, rs_sy};
           f = (rs_prevcnt == 16'hffff);
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
