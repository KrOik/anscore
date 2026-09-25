// Authored kernel. See ip/sprite_blend/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_sprite_blend (
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
// Palette as a decoded function: 16 x 32 bits of constant logic.
function [31:0] spr_pal; input [3:0] sidx; begin case (sidx)
    4'd00: spr_pal = 32'h00000000;
    4'd01: spr_pal = 32'hffaa0000;
    4'd02: spr_pal = 32'hff00aa00;
    4'd03: spr_pal = 32'hffaaaa00;
    4'd04: spr_pal = 32'hff0000aa;
    4'd05: spr_pal = 32'hffaa00aa;
    4'd06: spr_pal = 32'hff0055aa;
    4'd07: spr_pal = 32'hffaaaaaa;
    4'd08: spr_pal = 32'h80555555;
    4'd09: spr_pal = 32'hffff5555;
    4'd10: spr_pal = 32'hff55ff55;
    4'd11: spr_pal = 32'hffffff55;
    4'd12: spr_pal = 32'hff5555ff;
    4'd13: spr_pal = 32'hffff55ff;
    4'd14: spr_pal = 32'hff55ffff;
    4'd15: spr_pal = 32'hffffffff;
    default: spr_pal = 32'h00000000;
endcase end endfunction
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[31:4]!=0) begin f=1'b1; r=0; x=0; end
else begin
    sh=c[1:0];
    for(lane=0;lane<4;lane=lane+1) begin
        idx=a[(lane<<2)+:4];
        wide=spr_pal(idx);
        pc={24'd0,b[(lane<<3)+:8]};
        pb=wide[(sh<<3)+:8];
        if(wide[31:24]==8'd0) x[27]=1'b1;
        if(c[3]) pa=32'd255;
        else begin
            pa={28'd0,a[16+(lane<<2)+:4]};
            pa=(pa<<4)+pa;                       // coverage x 17, shift/add
            if(c[2]) pa=32'd255-pa;
        end
        if(pa==32'd0) begin
            r[(lane<<3)+:8]=pc[7:0]; x[4+lane]=1'b1;
        end else if(pa==32'd255) begin
            r[(lane<<3)+:8]=pb[7:0]; x[8+lane]=1'b1;
        end else begin
            if(pb>pc) begin ph=pb-pc; temp=0; end
            else if(pc>pb) begin ph=pc-pb; temp=1; end
            else begin ph=0; temp=0; x[lane]=1'b1; end
            ext=0;
            for(j=0;j<8;j=j+1) if(pa[j]) ext=ext+({25'd0,ph}<<j);
            wide2=ext+64'd127;
            pl=wide2[15:8];
            ph=pl+wide2[7:0];
            mask=pl;
            if(ph>=32'd255) mask=mask+32'd1;
            if(ph>=32'd510) mask=mask+32'd1;
            if(mask>pl) x[12+lane]=1'b1;
            if(temp==0) pl=pc+mask; else pl=pc-mask;
            r[(lane<<3)+:8]=pl[7:0];
            if(pl[7:0]!=pc[7:0]) i=i+1;   // aux[19:16] is the count
        end
    end
    x[19:16]=i;
    x[21:20]=sh;
    x[22]=c[2]; x[23]=c[3];
    if(a[3:0]==a[7:4] && a[7:4]==a[11:8] && a[11:8]==a[15:12]) x[24]=1'b1;
    if(a[19:16]==a[23:20] && a[23:20]==a[27:24] && a[27:24]==a[31:28]) x[25]=1'b1;
    if(r[7:0]==r[15:8] && r[15:8]==r[23:16] && r[23:16]==r[31:24]) x[26]=1'b1;
    if(sh==2'd3) x[28]=1'b1;
    if(a[3:0]==a[7:4]) x[29]=1'b1;
    if(a[11:8]==a[15:12]) x[30]=1'b1;
    if(a[19:16]>=4'd8 && a[23:20]>=4'd8 && a[27:24]>=4'd8 &&
       a[31:28]>=4'd8) x[31]=1'b1;
end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f;
            end
        end
    end
end
endmodule
