// Authored kernel. See ip/fadd_s32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_fadd_s32 (
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
reg sgneg, sub, fswap, tmpc;
reg [31:0] tmp;
reg [7:0] ea, eb;
reg [8:0] eA, eB, bef, dd;
reg [23:0] mA, mB;
reg nanA, nanB, infA, infB;
reg [63:0] wv, wq, wr, whalf, wmask, wms, wtmp;
reg [6:0] bln;
reg signed [8:0] kk;
reg signed [12:0] ef;
reg [24:0] om;
reg pinc, pstk, pinex, zres, ovf;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    sub=c[0];
if(c[31:1]!=31'd0) f=1'b1;
else begin
    sa=a[31]; ea=a[30:23]; mA={1'b0,a[22:0]};
    sb=b[31]; eb=b[30:23]; mB={1'b0,b[22:0]};
    if(sub) sb=sb^32'd1;
    sgneg=sa^sb; fswap=1'b0;
    nanA=(ea==8'hff && mA[22:0]!=23'd0);
    nanB=(eb==8'hff && mB[22:0]!=23'd0);
    infA=(ea==8'hff && mA[22:0]==23'd0);
    infB=(eb==8'hff && mB[22:0]==23'd0);
    if(nanA || nanB || (infA && infB && sa!=sb)) f=1'b1;
    else if(infA || infB) begin
        r={(infA ? sa : sb),8'hff,23'd0}; x[9]=1'b1; x[7]=sgneg;
        x[6]=1'b0; x[23:16]=8'd0;
    end else begin
        eA=(ea==8'd0) ? 9'd1 : {1'b0,ea};
        eB=(eb==8'd0) ? 9'd1 : {1'b0,eb};
        if(ea!=8'd0) mA[23]=1'b1;
        if(eb!=8'd0) mB[23]=1'b1;
        if(eA<eB || (eA==eB && mA<mB)) begin
            fswap=1'b1; tmp={7'd0,eA}; eA=eB; eB=tmp[8:0];
            tmp={8'd0,mA}; mA=mB; mB=tmp[23:0];
            tmpc=sa; sa=sb; sb=tmpc;
        end
        dd=eA-eB; pstk=1'b0; zres=1'b0; ovf=1'b0; pinc=1'b0;
        pinex=1'b0; kk=9'sd0; ef=13'sd0; om=25'd0; wv=64'd0;
        x[6]=fswap; x[7]=sgneg; x[23:16]=dd[7:0];
        if(mA==24'd0) begin
            r=sgneg ? 32'd0 : {sa,31'd0}; x[4]=1'b1;
        end else begin
            if(dd<=9'd25) begin
                wtmp={40'd0,mA}<<<dd;
                wv=sgneg ? (wtmp-{40'd0,mB}) : (wtmp+{40'd0,mB});
                bef=eB;
            end else begin
                wv={40'd0,mA}; bef=eA; pstk=(mB!=24'd0);
            end
            if(wv==64'd0) begin r=32'd0; x[4]=1'b1; end
            else begin
                bln=7'd0; for(i=0;i<50;i=i+1) if(wv[i]) bln=i+1;
                kk=$signed({2'd0,bln})-9'sd24;
                ef=$signed({4'd0,bef})+{{6'd0,bln}}-13'sd24;
                if(kk>9'sd0) begin
                    sh=kk;
                    wmask=(64'd1<<<sh)-64'd1;
                    wq=wv>>>sh; wr=wv&wmask;
                    whalf=64'd1<<<(sh-1);
                    pinc=(wr>whalf) || (wr==whalf && wq[0]);
                    om=wq+(pinc ? 25'd1 : 25'd0);
                    pinex=(wr!=64'd0) || pstk;
                end else begin
                    om=wv[24:0]; pinex=pstk;
                end
                if(ef>=13'sd1) begin
                    if(kk<=9'sd0) begin sh=24-bln; om=wv<<<sh; end
                    if(om[24]) begin om=om>>1;
                        ef=ef+13'sd1; end
                    if(ef>=13'sd255) begin
                        r={sa,8'hff,23'd0}; ovf=1'b1; x[3]=1'b1;
                    end else r={sa,ef[7:0],om[22:0]};
                end else begin
                    sh=bef-9'd1; wms=wv<<<sh;
                    r={sa,8'd0,wms[22:0]}; x[5]=1'b1;
                end
                x[0]=pstk; x[1]=pinex; x[2]=pinc;
                x[4]=(r[30:0]==31'd0);
            end
        end
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
