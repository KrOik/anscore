// Authored kernel. See ip/sinc3_decim/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_sinc3_decim (
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
reg sdres, sdfrz, sdau, sdsm, sdfin, sdsat, sdstk, sdhave;
reg [23:0] sdval;
reg [7:0] sdcnt, sdRm1, sdrat, sdlg, sdsh, sdshc, sdsh0;
reg signed [11:0] sdx;
reg signed [23:0] sdi1;
reg signed [27:0] sdi2;
reg signed [31:0] sdi3, sdp1, sdp2, sdp3, sdd1, sdd2, sdd3;
reg signed [31:0] sdout, sdreq;
reg signed [32:0] sdrnd;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    sdres = c[31];
sdfrz = c[30];
sdau = c[29];
sdsm = c[28];
sdx = $signed(a[11:0]);
sdRm1 = b[7:0];
sdrat = sdRm1 + 8'd1;
sdsh0 = c[5:0];
sdfin = 1'b0;
sdsat = 1'b0;
sdsh = 8'd0;
sdi1 = state_r[23:0];
sdi2 = state_r[51:24];
sdi3 = state_r[83:52];
sdp1 = state_r[115:84];
sdp2 = state_r[147:116];
sdp3 = state_r[179:148];
sdcnt = state_r[187:180];
sdout = state_r[219:188];
sdstk = state_r[220];
sdhave = state_r[221];
sdreq = sdout;
if (sdres) begin
    sdi1 = 24'sd0; sdi2 = 28'sd0; sdi3 = 32'sd0;
    sdp1 = 32'sd0; sdp2 = 32'sd0; sdp3 = 32'sd0;
    sdcnt = 8'd0; sdout = 32'sd0; sdreq = 32'sd0;
    sdstk = 1'b0; sdhave = 1'b0;
end
if (!sdfrz) begin
    sdi1 = sdi1 + sdx;
    sdi2 = sdi2 + sdi1;
    sdi3 = sdi3 + sdi2;
    sdfin = (sdcnt == sdRm1);
    if (sdfin) begin
        sdd1 = sdi3 - sdp1; sdp1 = sdi3;
        sdd2 = sdd1 - sdp2; sdp2 = sdd1;
        sdd3 = sdd2 - sdp3; sdp3 = sdd2;
        sdlg = 8'd0;
        for (i = 0; i < 8; i = i + 1) if (sdrat[i]) sdlg = i[7:0];
        sdsh = sdau ? (sdlg + (sdlg << 1)) : sdsh0;
        sdshc = (sdsh > 8'd31) ? 8'd31 : sdsh;
        if (sdshc == 8'd0) sdrnd = sdd3;
        else sdrnd = sdd3 + (33'sd1 <<< (sdshc - 8'd1));
        sdreq = sdrnd >>> sdshc;
        sdout = sdreq;
        sdhave = 1'b1;
        sdsat = (sdreq > 32'sd8388607) || (sdreq < -32'sd8388608);
        sdstk = sdstk | sdsat;
    end
    sdcnt = sdfin ? 8'd0 : (sdcnt + 8'd1);
end
if (sdsm && sdsat) sdval = sdreq[31] ? 24'h800000 : 24'h7fffff;
else sdval = sdreq[23:0];
if(a[31:12]!=0 || b[31:8]!=0 || c[27:6]!=0 || (sdRm1 > 8'd63)) f=1'b1;
else begin
    state_n[23:0] = sdi1;
    state_n[51:24] = sdi2;
    state_n[83:52] = sdi3;
    state_n[115:84] = sdp1;
    state_n[147:116] = sdp2;
    state_n[179:148] = sdp3;
    state_n[187:180] = sdcnt;
    state_n[219:188] = sdout;
    state_n[220] = sdstk;
    state_n[221] = sdhave;
    r = {sdhave, sdsm, sdres, sdau, sdfrz, sdstk, sdsat, sdfin, sdval};
    x = {sdout[31:24], sdRm1, sdsh, sdcnt};
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
