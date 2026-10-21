// Authored kernel. See ip/cordic_atan/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_cordic_atan (
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
function signed [21:0] atan_at; input [3:0] ix; begin atan_at=0; case (ix)
4'd0: atan_at=22'sd823550;  // atan(2^-0) = 0.7853981634 rad
4'd1: atan_at=22'sd486170;  // atan(2^-1) = 0.4636476090 rad
4'd2: atan_at=22'sd256879;  // atan(2^-2) = 0.2449786631 rad
4'd3: atan_at=22'sd130396;  // atan(2^-3) = 0.1243549945 rad
4'd4: atan_at=22'sd65451;  // atan(2^-4) = 0.0624188100 rad
4'd5: atan_at=22'sd32757;  // atan(2^-5) = 0.0312398334 rad
4'd6: atan_at=22'sd16383;  // atan(2^-6) = 0.0156237286 rad
4'd7: atan_at=22'sd8192;  // atan(2^-7) = 0.0078123411 rad
4'd8: atan_at=22'sd4096;  // atan(2^-8) = 0.0039062301 rad
4'd9: atan_at=22'sd2048;  // atan(2^-9) = 0.0019531225 rad
4'd10: atan_at=22'sd1024;  // atan(2^-10) = 0.0009765622 rad
4'd11: atan_at=22'sd512;  // atan(2^-11) = 0.0004882812 rad
4'd12: atan_at=22'sd256;  // atan(2^-12) = 0.0002441406 rad
4'd13: atan_at=22'sd128;  // atan(2^-13) = 0.0001220703 rad
4'd14: atan_at=22'sd64;  // atan(2^-14) = 0.0000610352 rad
4'd15: atan_at=22'sd32;  // atan(2^-15) = 0.0000305176 rad
default: ; endcase end endfunction
localparam signed [23:0] PID20 = 24'sd3294199;
reg signed [22:0] cx, cy, cxn, cyn, cmx, cmy, cmm, csv, csv2;
reg signed [21:0] cz, czn, cai;
reg signed [23:0] cang;
reg [4:0] ccnt, ccntn;
reg cfl, cfln, cfsg, cfsgn, chold, cdir;
reg [5:0] cbl;
reg [3:0] cix;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    cx=$signed(state_r[22:0]); cy=$signed(state_r[45:23]);
cz=$signed(state_r[67:46]); ccnt=state_r[72:68];
cfl=state_r[73]; cfsg=state_r[74];
cxn=cx; cyn=cy; czn=cz; ccntn=ccnt; cfln=cfl; cfsgn=cfsg;
chold=1'b0; cdir=1'b0; cix=4'd0; cai=22'sd0;
if(c[31]) begin
    if(a[15:0]==16'd0 && a[31:16]==16'd0) f=1'b1;
    else begin
        csv=$signed(a[15:0]); csv2=$signed(a[31:16]);
        if(csv<0) begin cmx=-csv; cmy=-csv2; cfln=1'b1;
            cfsgn=(csv2>=0); end
        else begin cmx=csv; cmy=csv2; cfln=1'b0; cfsgn=1'b1; end
        if(cmy<0) cmm=-cmy; else cmm=cmy;
        if(cmx>cmm) cmm=cmx;
        cbl=6'd0; for(i=0;i<23;i=i+1) if(cmm[i]) cbl=i+1;
        sh=20-cbl;
        cx=cmx<<<sh; cy=cmy<<<sh; cz=22'sd0; ccnt=5'd0; cix=4'd0;
    end
end else if(ccnt==5'd16) chold=1'b1;
else cix=ccnt[3:0];
if(!f) begin
    if(!chold) begin
        cai=atan_at(cix);
        if(cy>=0) begin cxn=cx+(cy>>>cix); cyn=cy-(cx>>>cix);
            czn=cz+cai; cdir=1'b1; end
        else begin cxn=cx-(cy>>>cix); cyn=cy+(cx>>>cix);
            czn=cz-cai; cdir=1'b0; end
        ccntn=ccnt+5'd1;
    end
    cang=czn + (cfln ? (cfsgn ? PID20 : -PID20) : 24'sd0);
    r=(cang+24'sd8)>>>4;
    x[3:0]=cix; x[4]=(ccntn==5'd16); x[5]=cfln; x[6]=cdir;
    x[7]=chold; x[23:8]=cyn[15:0]; x[31:24]=8'd0;
    state_n={181'd0, cfsgn, cfln, ccntn, czn, cyn, cxn};
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
