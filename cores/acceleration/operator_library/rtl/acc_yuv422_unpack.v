// Authored kernel. See ip/yuv422_unpack/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_yuv422_unpack (
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
    if(b!=0 || c[30:1]!=0) f=1'b1;
else begin
    if(c[31]) state_n=0; else state_n=state_r;
    lane=state_n[0];
    if(lane==0) begin
        pa=a[7:0]; pb=a[15:8]; pc=a[23:16]; ph=a[31:24];
    end else begin
        pa=a[15:8]; pb=a[7:0]; pc=a[31:24]; ph=a[23:16];
    end
    if(pb<32'd16 || pb>32'd240 || ph<32'd16 || ph>32'd240) begin
        f=1'b1; r=0; x=0; state_n=state_r;
    end else begin
        r[7:0]=pa; r[15:8]=pb; r[23:16]=ph; r[31:24]=pc;
        x[7:0]=pb; x[15:8]=ph;
        x[23:16]=state_n[7:1];
        x[24]=lane;
        x[25]=(pa==pc);
        x[26]=(pb==32'd128 && ph==32'd128);
        x[27]=(pa<32'd16 || pa>32'd235 || pc<32'd16 || pc>32'd235);
        x[28]=(pb==32'd16 || pb==32'd240);
        x[29]=(ph==32'd16 || ph==32'd240);
        if(state_r[7:1]==7'd127) x[30]=1'b1;
        if(c[31]) x[31]=1'b1;
        if(state_n[7:1]==7'd127) state_n[7:1]=0;
        else state_n[7:1]=state_n[7:1]+7'd1;
        if(c[0]) state_n[0]=~state_n[0];
    end
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
