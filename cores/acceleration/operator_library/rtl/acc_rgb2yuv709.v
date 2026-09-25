// Authored kernel. See ip/rgb2yuv709/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_rgb2yuv709 (
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

assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    pa={24'd0,a[7:0]}+{24'd0,a[15:8]}+{24'd0,a[23:16]}+{24'd0,a[31:24]};
pb={24'd0,b[7:0]}+{24'd0,b[15:8]}+{24'd0,b[23:16]}+{24'd0,b[31:24]};
pc={24'd0,c[7:0]}+{24'd0,c[15:8]}+{24'd0,c[23:16]}+{24'd0,c[31:24]};
swide=64'sd0 - (pa<<0) - (pa<<2) - (pa<<6) + (pa<<8) + (pb<<0) + (pb<<2) - (pb<<4) + (pb<<7) + (pb<<9) - (pc<<0) + (pc<<6) + 64'sd65536 + 64'sd2048;
mask=(swide>>>12);
swide=64'sd0 + (pa<<0) - (pa<<3) + (pa<<5) - (pa<<7) + (pb<<0) + (pb<<2) + (pb<<5) + (pb<<7) - (pb<<9) + (pc<<1) - (pc<<6) + (pc<<9) + 64'sd524288 + 64'sd2048;
temp=(swide>>>12);
if(temp<32'd16 || temp>32'd240) begin
    if(temp<32'd16) temp=32'd16; else temp=32'd240; x[31]=1'b1;
end
x[7:0]=temp[7:0];
x[29]=(temp==32'd16) || (temp==32'd240);
swide=64'sd0 + (pa<<1) - (pa<<6) + (pa<<9) - (pb<<0) + (pb<<3) - (pb<<5) + (pb<<7) - (pb<<9) - (pc<<0) - (pc<<3) - (pc<<5) + 64'sd524288 + 64'sd2048;
temp=(swide>>>12);
if(temp<32'd16 || temp>32'd240) begin
    if(temp<32'd16) temp=32'd16; else temp=32'd240; x[31]=1'b1;
end
x[15:8]=temp[7:0];
x[30]=(temp==32'd16) || (temp==32'd240);
for(lane=0;lane<4;lane=lane+1) begin
    ph={24'd0,a[(lane<<3)+:8]};
    pl={24'd0,b[(lane<<3)+:8]};
    pc={24'd0,c[(lane<<3)+:8]};
    swide=64'sd0 - (ph<<0) - (ph<<2) - (ph<<6) + (ph<<8) + (pl<<0) + (pl<<2) - (pl<<4) + (pl<<7) + (pl<<9) - (pc<<0) + (pc<<6) + 64'sd16384;
    if((swide & 64'sd1023) >= 64'sd512) x[16+lane]=1'b1;
    swide2=(swide + 64'sd512)>>>10;
    temp=swide2[31:0];
    if(temp<32'd16 || temp>32'd235) begin
        if(temp<32'd16) temp=32'd16; else temp=32'd235; x[31]=1'b1;
    end
    r[(lane<<3)+:8]=temp[7:0];
    if(temp==32'd16 || temp==32'd235) x[28]=1'b1;
    if(ph==pl && pl==pc) x[24+lane]=1'b1;
    ext=(mask>temp) ? (mask-temp) : (temp-mask);
    if(ext>=33'd8) x[20+lane]=1'b1;
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
