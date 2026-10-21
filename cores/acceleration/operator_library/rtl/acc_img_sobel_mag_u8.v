// Authored kernel. See ip/img_sobel_mag_u8/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_img_sobel_mag_u8 (
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
    if(a[31:24]!=0 || b[31:24]!=0 || c[31:24]!=0) f=1'b1;
else begin
    pa={24'd0,a[7:0]}+({24'd0,b[7:0]}<<1)+{24'd0,c[7:0]};
    pb={24'd0,a[23:16]}+({24'd0,b[23:16]}<<1)+{24'd0,c[23:16]};
    pc={24'd0,a[7:0]}+({24'd0,a[15:8]}<<1)+{24'd0,a[23:16]};
    ph={24'd0,c[7:0]}+({24'd0,c[15:8]}<<1)+{24'd0,c[23:16]};
    x[0]=(pa>pb);
    x[1]=(pc>ph);
    temp=(pa>pb) ? (pa-pb) : (pb-pa);
    mask=(pc>ph) ? (pc-ph) : (ph-pc);
    ext=temp+mask;
    if(ext>33'd255) begin r[7:0]=8'hff; x[2]=1'b1; end
    else r[7:0]=ext[7:0];
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
