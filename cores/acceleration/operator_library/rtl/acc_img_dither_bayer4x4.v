// Authored kernel. See ip/img_dither_bayer4x4/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_img_dither_bayer4x4 (
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
    if((c & 32'h7FFF_FFFF)!=0) f=1'b1;
else begin
    if(c[31]) begin pa=0; pb=0; end
    else begin pa=state_r[7:0]; pb=state_r[15:8]; end
    ph=pb & 32'd3;
    for(lane=0;lane<4;lane=lane+1) begin
        pl=(pa+lane)&32'd3;
        temp=pl^ph;
        mask={temp[0],ph[0],temp[1],ph[1]};
        swide=$signed({{24{b[(lane<<3)+7]}},b[(lane<<3)+:8]})
            +$signed({24'd0,a[(lane<<3)+:8]});
        if(swide<64'sd0) begin pc=0; r[8+lane]=1'b1; end
        else if(swide>64'sd255) begin pc=255; r[8+lane]=1'b1; end
        else pc=swide[7:0];
        pl=(pc<<2)+(mask<<4);
        temp=pl>>8;
        if(temp>32'd3) begin temp=32'd3; r[12+lane]=1'b1; end
        r[(lane<<1)+:2]=temp[1:0];
        mask=pl[7:0]-32'd128;
        x[(lane<<3)+:8]=mask[7:0];
    end
    temp=pa+32'd4;
    if(temp[8]) mask=pb+32'd1; else mask=pb;
    state_n[7:0]=temp[7:0]; state_n[15:8]=mask[7:0];
    r[23:16]=temp[7:0]; r[31:24]=mask[7:0];
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
