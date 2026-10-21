// Authored kernel. See ip/img_histogram_bin16_update/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_img_histogram_bin16_update (
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
    if((c & 32'h3F00_FF0F)!=0) f=1'b1;
else begin
    sh=((c>>4)&32'hf)<<4;
    r[15:0]=state_r[sh+:16];
    for(idx=0;idx<16;idx=idx+1) begin
        temp=(a[7:4]==idx)+(a[15:12]==idx)+(a[23:20]==idx)+(a[31:28]==idx)
            +(b[7:4]==idx)+(b[15:12]==idx)+(b[23:20]==idx)+(b[31:28]==idx);
        if(c[31]) mask=0;
        else if(c[30]) mask={c[23:16],c[23:16]};
        else mask=state_r[(idx<<4)+:16];
        if(mask==0 && temp!=0) x[16+idx]=1'b1;
        pa=mask+temp;
        if(pa>32'h0000_ffff) begin
            state_n[(idx<<4)+:16]=16'hffff; x[idx]=1'b1; f=1'b1;
        end else state_n[(idx<<4)+:16]=pa[15:0];
    end
    r[31:16]=state_n[sh+:16];
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
