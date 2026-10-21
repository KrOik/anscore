// Authored kernel. See ip/bf16_mul/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_bf16_mul (
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
function [23:0] bf_num;
  input [7:0] ax; input [7:0] ay; input [7:0] ex; input [7:0] ey;
  input sgn; input [15:0] pp;
  reg [5:0] bl; reg signed [11:0] eo, drop; reg [31:0] q, rr, hh;
  reg [31:0] msk; reg inc, inex, subn; integer k;
begin
  bl=6'd0; for(k=0;k<16;k=k+1) if(pp[k]) bl=k+1;
  eo=$signed({4'd0,ex})+$signed({4'd0,ey})+$signed({6'd0,bl})-12'sd142;
  subn=(eo<=12'sd0);
  if(!subn) drop=$signed({6'd0,bl})-12'sd8;
  else drop=12'sd135-$signed({4'd0,ex})-$signed({4'd0,ey});
  msk=32'd0; rr=32'd0; hh=32'd0; q=32'd0; k=0;
  if(drop>=12'sd1) begin
      if(drop>=12'sd17) begin q=32'd0; inc=1'b0; inex=1'b1; end
      else begin
          k=drop; msk=(32'd1<<<k)-32'd1;
          rr={16'd0,pp}&msk; hh=32'd1<<<(k-1);
          q={16'd0,pp}>>>k;
          inc=(rr>hh) || (rr==hh && q[0]); inex=(rr!=32'd0);
          if(inc) q=q+32'd1;
      end
  end else begin
      k=0-drop; q={16'd0,pp}<<<k; inc=1'b0; inex=1'b0;
  end
  if(subn) begin
      if(q>=32'd128) bf_num={1'b0,inex,inc,1'b1,1'b0,
                              3'd0,{sgn,8'd1,7'd0}};
      else bf_num={1'b0,inex,inc,1'b1,(q==32'd0),
                    3'd0,{sgn,8'd0,q[6:0]}};
  end else begin
      if(q>32'd255) begin q=q>>1; eo=eo+12'sd1; end
      if(eo>=12'sd255) bf_num={1'b1,1'b1,inc,1'b0,1'b0,
                                3'd0,{sgn,8'hff,7'd0}};
      else bf_num={1'b0,inex,inc,1'b0,1'b0,
                    3'd0,{sgn,eo[7:0],q[6:0]}};
  end
end
endfunction
reg [7:0] bax0, bay0, bex0, bey0, bax1, bay1, bex1, bey1;
reg bs0, bs1, bzero0, bzero1, binf0, binf1, bbad0, bbad1;
reg [15:0] bbx0, bby0, bbx1, bby1;
reg [23:0] bp0, bp1;
reg [15:0] bpr0, bpr1;
function [15:0] um8;
  input [7:0] u, v;
  integer k;
  reg [15:0] acc;
begin
  acc=16'd0;
  for(k=0;k<8;k=k+1) if(v[k]) acc=acc+({8'd0,u}<<<k);
  um8=acc;
end
endfunction
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    bbx0=a[15:0]; bby0=b[15:0]; bbx1=a[31:16]; bby1=b[31:16];
bex0=bbx0[14:7]; bey0=bby0[14:7]; bex1=bbx1[14:7]; bey1=bby1[14:7];
bax0=(bex0==8'd0) ? {1'b0,bbx0[6:0]} : {1'b1,bbx0[6:0]};
bay0=(bey0==8'd0) ? {1'b0,bby0[6:0]} : {1'b1,bby0[6:0]};
bax1=(bex1==8'd0) ? {1'b0,bbx1[6:0]} : {1'b1,bbx1[6:0]};
bay1=(bey1==8'd0) ? {1'b0,bby1[6:0]} : {1'b1,bby1[6:0]};
bs0=bbx0[15]^bby0[15]; bs1=bbx1[15]^bby1[15];
bzero0=1'b0; bzero1=1'b0; binf0=1'b0; binf1=1'b0;
bbad0=1'b0; bbad1=1'b0; bp0=24'd0; bp1=24'd0;
bpr0=um8(bax0,bay0); bpr1=um8(bax1,bay1);
if((bex0==8'hff && bbx0[6:0]!=7'd0) || (bey0==8'hff && bby0[6:0]!=7'd0))
    bbad0=1'b1;
if((bex1==8'hff && bbx1[6:0]!=7'd0) || (bey1==8'hff && bby1[6:0]!=7'd0))
    bbad1=1'b1;
if((bex0==8'hff && bay0==8'd0) || (bey0==8'hff && bax0==8'd0))
    bbad0=1'b1;
if(!bbad0) begin
    if((bex0==8'hff) || (bey0==8'hff)) begin
        binf0=1'b1; bp0={1'b1,1'b0,1'b0,1'b0,1'b0,3'd0,
                          {bs0,8'hff,7'd0}};
    end else if(bax0==8'd0 || bay0==8'd0) begin
        bzero0=1'b1; bp0={1'b0,1'b0,1'b0,1'b0,1'b1,3'd0,
                          {bs0,8'd0,7'd0}};
    end else bp0=bf_num(bax0,bay0,(bex0==8'd0)?8'd1:bex0,
                         (bey0==8'd0)?8'd1:bey0,bs0,bpr0[15:0]);
end
if((bex1==8'hff && bay1==8'd0) || (bey1==8'hff && bax1==8'd0))
    bbad1=1'b1;
if(!bbad1) begin
    if((bex1==8'hff) || (bey1==8'hff)) begin
        binf1=1'b1; bp1={1'b1,1'b0,1'b0,1'b0,1'b0,3'd0,
                          {bs1,8'hff,7'd0}};
    end else if(bax1==8'd0 || bay1==8'd0) begin
        bzero1=1'b1; bp1={1'b0,1'b0,1'b0,1'b0,1'b1,3'd0,
                          {bs1,8'd0,7'd0}};
    end else bp1=bf_num(bax1,bay1,(bex1==8'd0)?8'd1:bex1,
                         (bey1==8'd0)?8'd1:bey1,bs1,bpr1[15:0]);
end
if(bbad0 || bbad1) f=1'b1;
else begin
    r={bp1[15:0],bp0[15:0]};
    x[0]=bp0[23]; x[1]=bp0[19]; x[2]=bp0[22]; x[3]=bp0[21];
    x[4]=bp0[20]; x[5]=bp1[23]; x[6]=bp1[19]; x[7]=bp1[22];
    x[8]=bp1[21]; x[9]=bp1[20]; x[15:10]=6'd0; x[31:16]=bpr0[15:0];
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
