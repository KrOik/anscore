// Authored kernel. See ip/float2fix_rne/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_float2fix_rne (
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
function [31:0] f2f_lane;
  input [31:0] u;
  input signed [7:0] nn;
  reg [7:0] fe;
  reg [23:0] fm;
  reg signed [11:0] ft;
  reg [63:0] fc, frr, fhh, fmk;
  integer fk;
  reg finex, fsat, fbad, fneg, finc;
  reg [63:0] fout;
  reg [15:0] fof;
begin
  fe=u[30:23]; fm=u[22:0]; fneg=u[31];
  fbad=1'b0; fsat=1'b0; finex=1'b0; finc=1'b0; fout=64'd0;
  fof=16'd0; ft=12'sd0;
  if(fe==8'hff) fbad=1'b1;
  else begin
    ft=$signed({3'd0,fe})+nn-12'sd150;
    if(fe!=8'd0) fm=fm|24'h800000;
    else ft=12'sd1+nn-12'sd150;

    if(fm==24'd0) fout=64'd0;
    else if(ft>=12'sd16) fout=64'h100000000;
    else if(ft>=12'sd0) begin
      fk=ft; fout={40'd0,fm}<<<fk;
    end else if((0-ft)>=12'sd25) begin fout=64'd0; finex=1'b1; end
    else begin
      fk=0-ft;
      fmk=(64'd1<<<fk)-64'd1;
      frr={40'd0,fm}&fmk;
      fhh=64'd1<<<(fk-1);
      fout={40'd0,fm}>>>fk;
      finc=(frr>fhh) || (frr==fhh && fout[0]);
      finex=(frr!=64'd0);
      if(finc) fout=fout+64'd1;
    end
    if(fneg) begin
      if(fout>64'd32768) begin fsat=1'b1; fof=16'h8000; end
      else fof=16'd0-fout[15:0];
    end else begin
      if(fout>64'd32767) begin fsat=1'b1; fof=16'h7fff; end
      else fof=fout[15:0];
    end
  end
  f2f_lane={fbad,fsat,finex,finc,12'd0,fof};
end
endfunction
reg signed [7:0] nsc;
reg [31:0] p0, p1;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[31:8]!=24'd0) f=1'b1;
else begin
    nsc=$signed(c[7:0]);
    p0=f2f_lane(a,nsc); p1=f2f_lane(b,nsc);
    if(p0[31] || p1[31]) f=1'b1;
    else begin
        r={p1[15:0],p0[15:0]};
        x[0]=p0[30]; x[1]=p0[29]; x[2]=p0[28]; x[3]=1'b0;
        x[4]=p1[30]; x[5]=p1[29]; x[6]=p1[28]; x[7]=1'b0;
        x[15:8]=c[7:0]; x[31:16]=16'd0;
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
