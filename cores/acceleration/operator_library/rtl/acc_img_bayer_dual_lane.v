// Authored kernel. See ip/img_bayer_dual_lane/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_img_bayer_dual_lane (
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
    if(c[31:16]!=0) f=1'b1;
else begin
    for(lane=0;lane<2;lane=lane+1) begin
        if(lane==0) begin
            pa={24'd0,a[15:8]}; pb={24'd0,a[7:0]};
            pc={24'd0,a[23:16]}; ph={24'd0,c[7:0]}; pl={24'd0,b[15:8]};
        end else begin
            pa={24'd0,b[23:16]}; pb={24'd0,b[15:8]};
            pc={24'd0,b[31:24]}; ph={24'd0,a[23:16]}; pl={24'd0,c[15:8]};
        end
        temp=(ph<pl) ? (pl-ph) : (ph-pl);
        mask=(pc<pb) ? (pb-pc) : (pc-pb);
        ph=ph+pl;
        pl=pa<<1;
        ext=temp<<1;
        temp=(ph<pl) ? (pl-ph) : (ph-pl);
        ext=ext+temp;
        pc=pc+pb;
        wide=mask<<1;
        temp=(pc<pl) ? (pl-pc) : (pc-pl);
        wide=wide+{32'd0,temp};
        if(ext<wide) begin temp=(ph+32'd1)>>1; x[(lane<<1)]=1'b1; end
        else if(wide<ext) begin temp=(pc+32'd1)>>1; x[(lane<<1)+1]=1'b1; end
        else begin temp=(ph+pc+32'd2)>>2;
            x[(lane<<1)]=1'b1; x[(lane<<1)+1]=1'b1;
        end
        r[(lane<<3)+:8]=temp[7:0];
        if(lane==0) r[23:16]=pa; else r[31:24]=pa;
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
                result<=r; aux<=x; fault<=f;
            end
        end
    end
end
endmodule
