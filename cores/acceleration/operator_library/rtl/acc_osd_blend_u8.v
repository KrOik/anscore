// Authored kernel. See ip/osd_blend_u8/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_osd_blend_u8 (
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
    for(lane=0;lane<4;lane=lane+1) begin
    pa={24'd0,a[(lane<<3)+:8]};
    pb={24'd0,b[(lane<<3)+:8]};
    pc={24'd0,c[(lane<<3)+:8]};
    if(pc==32'd0) begin
        r[(lane<<3)+:8]=pb[7:0]; x[lane]=1'b1;
    end else if(pc==32'd255) begin
        r[(lane<<3)+:8]=pa[7:0]; x[4+lane]=1'b1;
    end else begin
        if(pa>pb) begin ph=pa-pb; temp=0; end
        else if(pb>pa) begin ph=pb-pa; temp=1; end
        else begin ph=0; temp=0; x[8+lane]=1'b1; end
        ext=0;
        for(i=0;i<8;i=i+1) if(pc[i]) ext=ext+({25'd0,ph}<<i);
        wide=ext+64'd127;
        pl=wide[15:8];
        ph=pl+wide[7:0];
        mask=pl;
        if(ph>=32'd255) mask=mask+32'd1;
        if(ph>=32'd510) mask=mask+32'd1;
        if(mask>pl) x[12+lane]=1'b1;
        if(temp==0) pl=pb+mask; else pl=pb-mask;
        r[(lane<<3)+:8]=pl[7:0];
        if(pl!=pa && pl!=pb) x[16+lane]=1'b1;
    end
end
if(c[7:0]==c[15:8] && c[15:8]==c[23:16] && c[23:16]==c[31:24]) x[20]=1'b1;
if(x[7:0]!=0) x[21]=1'b1;
if(r[7:0]==r[15:8] && r[15:8]==r[23:16] && r[23:16]==r[31:24]) x[22]=1'b1;
if(c[7:0]>32'd127 && c[15:8]>32'd127 && c[23:16]>32'd127 &&
   c[31:24]>32'd127) x[23]=1'b1;
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
