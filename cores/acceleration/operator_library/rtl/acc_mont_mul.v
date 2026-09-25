// Authored kernel. See ip/mont_mul/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_mont_mul (
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
function [21:0] n_at; input [2:0] ix; begin n_at=22'd0; case (ix)
3'd0: n_at=22'd2097153;
3'd1: n_at=22'd1048577;
3'd2: n_at=22'd4194303;
3'd3: n_at=22'd46079;
3'd4: n_at=22'd1398135;
3'd5: n_at=22'd1048575;
3'd6: n_at=22'd1193051;
3'd7: n_at=22'd2775635;
default: ; endcase end endfunction
function [10:0] np_at; input [2:0] ix; begin np_at=11'd0; case (ix)
3'd0: np_at=11'd2047;  // -N^-1 mod 2^11 of N=2047
3'd1: np_at=11'd2047;  // -N^-1 mod 2^11 of N=2047
3'd2: np_at=11'd1;  // -N^-1 mod 2^11 of N=1
3'd3: np_at=11'd1025;  // -N^-1 mod 2^11 of N=1025
3'd4: np_at=11'd953;  // -N^-1 mod 2^11 of N=953
3'd5: np_at=11'd1;  // -N^-1 mod 2^11 of N=1
3'd6: np_at=11'd1069;  // -N^-1 mod 2^11 of N=1069
3'd7: np_at=11'd1573;  // -N^-1 mod 2^11 of N=1573
default: ; endcase end endfunction
function [21:0] um11;
  input [10:0] u, v;
  integer k;
  reg [21:0] acc;
begin
  acc=22'd0;
  for(k=0;k<11;k=k+1) if(v[k]) acc=acc+({11'd0,u}<<<k);
  um11=acc;
end
endfunction
reg [44:0] mc, mcn, madd;
reg [21:0] mn, mnl, mnh;
reg [21:0] mprod, pnlo, pnnh;
reg [10:0] mnp, mm, mslo;
reg [1:0] mlimb, mlimbn;
reg [2:0] mk;
reg mdone, mhold, msub, msubn;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    mc=state_r[44:0]; mn=state_r[66:45]; mnp=state_r[77:67];
mlimb=state_r[79:78]; mk=state_r[82:80]; mm=state_r[93:83];
mdone=state_r[94]; msub=state_r[95];
mcn=mc; mlimbn=mlimb; msubn=msub; mhold=1'b0;
madd=45'd0; mslo=11'd0; mprod=22'd0; pnlo=22'd0; pnnh=22'd0;
mnl=22'd0; mnh=22'd0;
if(c[31]) begin
    if(c[30:3]!=28'd0) f=1'b1;
    else begin
        mk=c[2:0]; mn=n_at(mk); mnp=np_at(mk);
        mc={1'b0,a[21:0],b[21:0]};
        if(mc[43:22]>=mn) f=1'b1;
        else begin
            mcn=mc; mlimbn=2'd0; mm=11'd0; mdone=1'b0; msubn=1'b0;
        end
    end
end else if(mlimb==2'd3) begin
    mhold=1'b1; mcn=mc; mm=11'd0;
end else begin
    mnl=mn[10:0]; mnh=mn[21:11];
    if(mlimb==2'd0 || mlimb==2'd1) begin
        mslo=mc[10:0];
        mprod=um11(mslo,mnp);
        mm=mprod[10:0];
        pnlo=um11(mm,mnl);
        pnnh=um11(mm,mnh);
        madd={22'd0,pnlo}+({22'd0,pnnh}<<<11);
        mcn=(mc+madd)>>11;
        mlimbn=mlimb+2'd1;
      end else begin
        if(mc>=mn) begin mcn=mc-{23'd0,mn}; msubn=1'b1; end
        else mcn=mc;
        mlimbn=2'd3; mdone=1'b1; mm=11'd0;
    end
end
if(!f) begin
    r=mcn[31:0];
    x[2:0]=mk; x[4:3]=mlimbn; x[5]=mdone; x[6]=mhold;
    x[7]=msubn; x[18:8]=mm; x[31:19]=mcn[12:0];
    state_n={160'd0, msubn, mdone, mm, mk, mlimbn, mnp, mn, mcn};
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
