// Authored kernel. See ip/yuv2rgb709/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_yuv2rgb709 (
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
    if(b[31:16]!=0 || c!=0) f=1'b1;
else begin
    swide=64'sd0 + (a[7:0]<<3) + (a[7:0]<<5) + (a[7:0]<<7) + (a[7:0]<<10) - 64'sd18560;
    if(a[7:0]<32'd16 || a[7:0]>32'd235 || a[15:8]<32'd16 || a[15:8]>32'd240 || a[23:16]<32'd16 || a[23:16]>32'd240) x[24]=1'b1;
    if(a[15:8]==32'd128 && a[23:16]==32'd128) x[22]=1'b1;
    swide2=swide - (a[23:16]<<2) - (a[23:16]<<4) + (a[23:16]<<6) - (a[23:16]<<8) + (a[23:16]<<11) - 64'sd235008;
    if((swide2 & 64'sd1023) < 64'sd512) x[17]=1'b1;
    swide2=(swide2>>>10);
    if(swide2<64'sd0) begin r[7:0]=8'd0; x[16]=1'b1; end
    else if(swide2>64'sd255) begin r[7:0]=8'd255; x[16]=1'b1; end
    else r[7:0]=swide2[7:0];
    swide2=swide - (a[15:8]<<1) + (a[15:8]<<3) + (a[15:8]<<5) - (a[15:8]<<8) - (a[23:16]<<1) - (a[23:16]<<5) - (a[23:16]<<9) + 64'sd97792;
    if((swide2 & 64'sd1023) < 64'sd512) x[17]=1'b1;
    swide2=(swide2>>>10);
    if(swide2<64'sd0) begin r[15:8]=8'd0; x[16]=1'b1; end
    else if(swide2>64'sd255) begin r[15:8]=8'd255; x[16]=1'b1; end
    else r[15:8]=swide2[7:0];
    swide2=swide - (a[15:8]<<0) + (a[15:8]<<2) - (a[15:8]<<4) + (a[15:8]<<7) + (a[15:8]<<11) - 64'sd276864;
    if((swide2 & 64'sd1023) < 64'sd512) x[17]=1'b1;
    swide2=(swide2>>>10);
    if(swide2<64'sd0) begin r[23:16]=8'd0; x[16]=1'b1; end
    else if(swide2>64'sd255) begin r[23:16]=8'd255; x[16]=1'b1; end
    else r[23:16]=swide2[7:0];
    if(r[7:0]==r[15:8] && r[15:8]==r[23:16]) x[20]=1'b1;
    swide=64'sd0 + (a[31:24]<<3) + (a[31:24]<<5) + (a[31:24]<<7) + (a[31:24]<<10) - 64'sd18560;
    if(a[31:24]<32'd16 || a[31:24]>32'd235 || b[7:0]<32'd16 || b[7:0]>32'd240 || b[15:8]<32'd16 || b[15:8]>32'd240) x[25]=1'b1;
    if(b[7:0]==32'd128 && b[15:8]==32'd128) x[23]=1'b1;
    swide2=swide - (b[15:8]<<2) - (b[15:8]<<4) + (b[15:8]<<6) - (b[15:8]<<8) + (b[15:8]<<11) - 64'sd235008;
    if((swide2 & 64'sd1023) < 64'sd512) x[19]=1'b1;
    swide2=(swide2>>>10);
    if(swide2<64'sd0) begin r[31:24]=8'd0; x[18]=1'b1; end
    else if(swide2>64'sd255) begin r[31:24]=8'd255; x[18]=1'b1; end
    else r[31:24]=swide2[7:0];
    swide2=swide - (b[7:0]<<1) + (b[7:0]<<3) + (b[7:0]<<5) - (b[7:0]<<8) - (b[15:8]<<1) - (b[15:8]<<5) - (b[15:8]<<9) + 64'sd97792;
    if((swide2 & 64'sd1023) < 64'sd512) x[19]=1'b1;
    swide2=(swide2>>>10);
    if(swide2<64'sd0) begin x[7:0]=8'd0; x[18]=1'b1; end
    else if(swide2>64'sd255) begin x[7:0]=8'd255; x[18]=1'b1; end
    else x[7:0]=swide2[7:0];
    swide2=swide - (b[7:0]<<0) + (b[7:0]<<2) - (b[7:0]<<4) + (b[7:0]<<7) + (b[7:0]<<11) - 64'sd276864;
    if((swide2 & 64'sd1023) < 64'sd512) x[19]=1'b1;
    swide2=(swide2>>>10);
    if(swide2<64'sd0) begin x[15:8]=8'd0; x[18]=1'b1; end
    else if(swide2>64'sd255) begin x[15:8]=8'd255; x[18]=1'b1; end
    else x[15:8]=swide2[7:0];
    if(r[31:24]==x[7:0] && x[7:0]==x[15:8]) x[21]=1'b1;
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
