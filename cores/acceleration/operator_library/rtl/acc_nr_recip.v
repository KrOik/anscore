// Authored kernel. See ip/nr_recip/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_nr_recip (
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
function signed [11:0] seed_at; input [5:0] ix; begin seed_at=0; case (ix)
6'd0: seed_at=12'sd0;  // bin centre D=32
6'd1: seed_at=12'sd0;  // bin centre D=96
6'd2: seed_at=12'sd0;  // bin centre D=160
6'd3: seed_at=12'sd0;  // bin centre D=224
6'd4: seed_at=12'sd0;  // bin centre D=288
6'd5: seed_at=12'sd0;  // bin centre D=352
6'd6: seed_at=12'sd0;  // bin centre D=416
6'd7: seed_at=12'sd0;  // bin centre D=480
6'd8: seed_at=12'sd0;  // bin centre D=544
6'd9: seed_at=12'sd0;  // bin centre D=608
6'd10: seed_at=12'sd0;  // bin centre D=672
6'd11: seed_at=12'sd0;  // bin centre D=736
6'd12: seed_at=12'sd0;  // bin centre D=800
6'd13: seed_at=12'sd0;  // bin centre D=864
6'd14: seed_at=12'sd0;  // bin centre D=928
6'd15: seed_at=12'sd0;  // bin centre D=992
6'd16: seed_at=12'sd0;  // bin centre D=1056
6'd17: seed_at=12'sd0;  // bin centre D=1120
6'd18: seed_at=12'sd0;  // bin centre D=1184
6'd19: seed_at=12'sd0;  // bin centre D=1248
6'd20: seed_at=12'sd0;  // bin centre D=1312
6'd21: seed_at=12'sd0;  // bin centre D=1376
6'd22: seed_at=12'sd0;  // bin centre D=1440
6'd23: seed_at=12'sd0;  // bin centre D=1504
6'd24: seed_at=12'sd0;  // bin centre D=1568
6'd25: seed_at=12'sd0;  // bin centre D=1632
6'd26: seed_at=12'sd0;  // bin centre D=1696
6'd27: seed_at=12'sd0;  // bin centre D=1760
6'd28: seed_at=12'sd0;  // bin centre D=1824
6'd29: seed_at=12'sd0;  // bin centre D=1888
6'd30: seed_at=12'sd0;  // bin centre D=1952
6'd31: seed_at=12'sd0;  // bin centre D=2016
6'd32: seed_at=12'sd1922;  // bin centre D=2080
6'd33: seed_at=12'sd1681;  // bin centre D=2144
6'd34: seed_at=12'sd1454;  // bin centre D=2208
6'd35: seed_at=12'sd1240;  // bin centre D=2272
6'd36: seed_at=12'sd1038;  // bin centre D=2336
6'd37: seed_at=12'sd847;  // bin centre D=2400
6'd38: seed_at=12'sd665;  // bin centre D=2464
6'd39: seed_at=12'sd493;  // bin centre D=2528
6'd40: seed_at=12'sd329;  // bin centre D=2592
6'd41: seed_at=12'sd173;  // bin centre D=2656
6'd42: seed_at=12'sd24;  // bin centre D=2720
6'd43: seed_at=-12'sd118;  // bin centre D=2784
6'd44: seed_at=-12'sd253;  // bin centre D=2848
6'd45: seed_at=-12'sd383;  // bin centre D=2912
6'd46: seed_at=-12'sd506;  // bin centre D=2976
6'd47: seed_at=-12'sd625;  // bin centre D=3040
6'd48: seed_at=-12'sd739;  // bin centre D=3104
6'd49: seed_at=-12'sd848;  // bin centre D=3168
6'd50: seed_at=-12'sd953;  // bin centre D=3232
6'd51: seed_at=-12'sd1054;  // bin centre D=3296
6'd52: seed_at=-12'sd1151;  // bin centre D=3360
6'd53: seed_at=-12'sd1244;  // bin centre D=3424
6'd54: seed_at=-12'sd1334;  // bin centre D=3488
6'd55: seed_at=-12'sd1421;  // bin centre D=3552
6'd56: seed_at=-12'sd1504;  // bin centre D=3616
6'd57: seed_at=-12'sd1585;  // bin centre D=3680
6'd58: seed_at=-12'sd1663;  // bin centre D=3744
6'd59: seed_at=-12'sd1738;  // bin centre D=3808
6'd60: seed_at=-12'sd1811;  // bin centre D=3872
6'd61: seed_at=-12'sd1881;  // bin centre D=3936
6'd62: seed_at=-12'sd1950;  // bin centre D=4000
6'd63: seed_at=-12'sd2016;  // bin centre D=4064
default: ; endcase end endfunction
function signed [23:0] sm12;
  input signed [11:0] u, v;
  integer k;
  reg su, sv; reg [11:0] au, av;
  reg signed [23:0] acc;
begin
  su=(u<0); sv=(v<0);
  au=su ? (12'd0-u) : u;
  av=sv ? (12'd0-v) : v;
  acc=24'sd0;
  for(k=0;k<12;k=k+1) if(av[k]) acc=acc+({12'd0,au}<<<k);
  sm12=(su^sv) ? -acc : acc;
end
endfunction
reg signed [26:0] ne, nv, nvn, na24, nt24, ntq, ng, nco, ntt, nd;
reg signed [26:0] nlim;
reg signed [23:0] np1, np2;
reg signed [31:0] nres;
reg [12:0] nY;
reg [3:0] nph;
reg [5:0] nbin;
reg nsg, nwait;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ne=$signed(state_r[11:0]); nv=$signed(state_r[23:12]);
nph=state_r[27:24]; nsg=state_r[28];
nbin=6'd0; nvn=nv; nwait=1'b0; nt24=27'sd0; nvn=nv;
if(c[31]) begin
    if(a[11:0]<=12'd2048) f=1'b1;
    else begin
        ne=$signed({1'b0,a[11:0]})-27'sd3072;
        nbin=a[11:6]; nv=seed_at(nbin); nvn=nv; nph=4'd0; nsg=a[12];
    end
end else if(nph==4'd4) nwait=1'b1;
else begin
    nd=27'sd3072+ne;
    np1=sm12(ne,nv);
    na24=27'sd18874368+(ne<<<12)+(ne<<<11)+(nv<<<11)+(nv<<<10)+np1;
    nt24=27'sd16777216-na24;
    if(nph==4'd3) begin
        ntt=nt24<<<1;
        if(ntt>=nd) nvn=nv+27'sd1;
        else if(ntt<=-nd) nvn=nv-27'sd1;
        else nvn=nv;
        nph=4'd4;
    end else begin
        sh=(nph==4'd0) ? 7 : ((nph==4'd1) ? 3 : 1);
        nlim=27'sd2048<<<sh;
        if(nt24>=nlim || nt24<=-nlim) f=1'b1;
        else begin
            ntq=nt24>>>sh;
            np2=sm12(nv,ntq);
            ng=(ntq<<<12)+(ntq<<<11)+np2;
            nco=(ng+(27'sd1<<<(23-sh)))>>>(24-sh);
            nvn=nv+nco;
            if(nvn<-(27'sd1<<<11) || nvn>(27'sd1<<<11)-27'sd1) f=1'b1;
            else nph=nph+4'd1;
        end
    end
end
if(!f) begin
    nY=13'd6144+nvn[12:0];
    nres=nsg ? (32'sd0-$signed({19'd0,nY})) : $signed({19'd0,nY});
    r=nres; x[2:0]=nph; x[3]=(nph==4'd4); x[4]=nsg; x[5]=nwait;
    x[9:6]=4'd0; x[15:10]=nbin; x[31:16]=nt24[15:0];
    state_n={227'd0, nsg, nph, nvn[11:0], ne[11:0]};
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
