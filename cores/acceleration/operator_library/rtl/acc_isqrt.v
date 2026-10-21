// Authored kernel. See ip/isqrt/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_isqrt (
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
reg [32:0] sqm, sqn, sqadd, sqbit, sqsh;
reg [15:0] sqr, sqrn;
reg [4:0] sqi, sqin;
reg sqhold, sqdon, sqdonn;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    sqm=state_r[32:0]; sqr=state_r[48:33]; sqi=state_r[53:49];
sqdon=state_r[54];
sqn=sqm; sqrn=sqr; sqin=sqi; sqdonn=sqdon; sqhold=1'b0; sqadd=33'd0;
if(c[31]) begin
    sqm={1'b0,a}; sqr=16'd0; sqi=5'd15; sqdon=1'b0;
    sqn=sqm; sqrn=sqr; sqin=sqi; sqdonn=sqdon;
end else if(sqdon) begin
    sqhold=1'b1;
end else begin
    sh=sqi+5'd1;
    sqsh={17'd0,sqr}<<<sh;
    sh=sqi+sqi;
    sqbit=33'd1<<<sh;
    sqadd=sqsh|sqbit;
    if(sqm>=sqadd) begin sqn=sqm-sqadd; sqin=sqi;
        sh=sqi; sqrn=sqr|(16'd1<<<sh); end
    else begin sqn=sqm; sqrn=sqr; end
    sqin = (sqi==5'd0) ? 5'd0 : sqi-5'd1;
    sqdonn = (sqi==5'd0);
end
r={16'd0,sqrn};
x[4:0]=sqin; x[5]=sqdonn; x[6]=sqhold; x[31:7]=sqn[24:0];
state_n={201'd0, sqdonn, sqin, sqrn, sqn};
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
