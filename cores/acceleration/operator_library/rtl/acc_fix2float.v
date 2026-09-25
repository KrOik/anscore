// Authored kernel. See ip/fix2float/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_fix2float (
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
reg [31:0] fxmag, fxn;
reg [63:0] fxmask, fxr, fxhalf;
reg signed [10:0] fxe, fxf, fxdrop;
reg [5:0] fxlz;
reg [24:0] fxk;
reg [7:0] fxr8;
reg fxinc, fxsticky, fxunder, fxover;
reg fxsign;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[31:8]!=24'd0) f=1'b1;
else begin
    fxsign=a[31]; fxe=$signed(c[7:0]);
    fxmag=a[31] ? ((~a)+32'd1) : a;
    pl=32'd0; for(i=0;i<32;i=i+1) if(fxmag[i]) pl=i+1;
    fxlz=6'd32-pl[5:0];
    fxn=fxmag<<<fxlz;
    fxf=fxe-{{5{1'b0}},fxlz}+11'sd127;
    x[7:0]=c[7:0]; x[14]=fxsign; x[25:20]=fxlz; x[19:15]=5'd0;
    x[31:26]=6'd0; x[10]=1'b0; x[11]=1'b0; x[13]=1'b0;
    if(fxmag==32'd0) begin
        r={fxsign,31'd0}; x[12]=1'b1; x[13]=1'b1;
    end else if(fxf>=11'sd1) begin
        fxk={1'd0,fxn[31:8]}; fxr8=fxn[7:0];
        fxsticky=(fxr8!=8'd0);
        fxinc=(fxr8>8'h80) || (fxr8==8'h80 && fxk[0]);
        if(fxinc) fxk=fxk+25'd1;
        if(fxk[24]) begin fxk=fxk>>1; fxf=fxf+11'sd1; end
        if(fxf>=11'sd255) begin
            r={fxsign,8'hff,23'd0}; x[11]=1'b1; x[8]=1'b0;
            x[9]=fxsticky; x[12]=1'b0;
        end else begin
            r={fxsign,fxf[7:0],fxk[22:0]};
            x[8]=fxinc; x[9]=fxsticky; x[12]=!fxsticky;
        end
    end else begin
        fxdrop=11'sd9-fxf;
        if(fxdrop>=11'sd33) begin
            fxk=25'd0; fxsticky=1'b1; fxinc=1'b0;
        end else begin
            sh=fxdrop;
            fxk={1'b0,fxn>>sh};
            fxmask=(64'd1<<<sh)-64'd1;
            fxr={32'd0,fxn}&fxmask;
            fxhalf=64'd1<<<(sh-1);
            fxsticky=(fxr!=64'd0);
            fxinc=(fxr>fxhalf) || (fxr==fxhalf && fxk[0]);
            if(fxinc) fxk=fxk+25'd1;
        end
        x[10]=1'b1; x[8]=fxinc; x[9]=fxsticky; x[12]=!fxsticky;
        r=fxk[23] ? {fxsign,8'd1,23'd0} : {fxsign,8'd0,fxk[22:0]};
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
