// Authored kernel. See ip/cordic_sincos/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_cordic_sincos (
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
reg csres, cshd, csro, csck, csdir, csq, csp, csm, csfold, cswrap, csd;
reg [13:0] csstep, cslim;
reg [11:0] csoc, csos;
reg signed [13:0] csload, csacc, csacc0;
reg signed [11:0] csscos, csssin;
reg signed [15:0] csum, csum2, csx16, csf1, csst, czw, csxw, csyw;
reg signed [15:0] csxs, csys;
reg signed [31:0] csxse, csyse, csxpr, csypr;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    csres = c[31];
csck = c[30];
csro = c[29];
cshd = c[28];
csload = a[13:0];
csstep = b[13:0];
csdir = b[15];
cslim = c[27:14];
csacc0 = state_r[13:0];
if (csres) begin
    csacc = csload; cswrap = 1'b0;
end else if (cshd) begin
    csacc = csacc0; cswrap = 1'b0;
end else begin
    csst = $signed({2'b00, csstep});
    if (csdir) csst = -csst;
    csum = csacc0 + csst;
    cswrap = (csum > 16'sd8191) || (csum < -16'sd8192);
    if (csum > 16'sd8191) csum2 = csum - 16'sd16384;
    else if (csum < -16'sd8192) csum2 = csum + 16'sd16384;
    else csum2 = csum;
    csacc = csum2[13:0];
end
csx16 = csacc;
csq = (csx16 > 16'sd4095) || (csx16 < -16'sd4096);
if (!csq) csf1 = csx16;
else if (csx16 < 16'sd0) csf1 = csx16 + 16'sd8192;
else csf1 = csx16 - 16'sd8192;
csp = (csf1 > 16'sd2048);
csm = (csf1 < -16'sd2048);
if (csp) czw = csf1 - 16'sd4096;
else if (csm) czw = csf1 + 16'sd4096;
else czw = csf1;
csfold = csq | csp | csm;
case ({csq, csp, csm})
    3'b000: begin csxw = 16'sd1024; csyw = 16'sd0; end
    3'b001: begin csxw = 16'sd0; csyw = -16'sd1024; end
    3'b010: begin csxw = 16'sd0; csyw = 16'sd1024; end
    3'b100: begin csxw = -16'sd1024; csyw = 16'sd0; end
    3'b101: begin csxw = 16'sd0; csyw = 16'sd1024; end
    3'b110: begin csxw = 16'sd0; csyw = -16'sd1024; end
    default: begin csxw = 16'sd1024; csyw = 16'sd0; end
endcase
csd = (czw >= 16'sd0);
csxs = csxw;
csys = csyw;
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd2048;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd2048;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd1) >>> 1);
csys = ((csyw + 16'sd1) >>> 1);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd1209;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd1209;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd2) >>> 2);
csys = ((csyw + 16'sd2) >>> 2);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd639;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd639;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd4) >>> 3);
csys = ((csyw + 16'sd4) >>> 3);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd324;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd324;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd8) >>> 4);
csys = ((csyw + 16'sd8) >>> 4);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd163;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd163;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd16) >>> 5);
csys = ((csyw + 16'sd16) >>> 5);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd81;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd81;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd32) >>> 6);
csys = ((csyw + 16'sd32) >>> 6);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd41;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd41;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd64) >>> 7);
csys = ((csyw + 16'sd64) >>> 7);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd20;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd20;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd128) >>> 8);
csys = ((csyw + 16'sd128) >>> 8);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd10;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd10;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd256) >>> 9);
csys = ((csyw + 16'sd256) >>> 9);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd5;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd5;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd512) >>> 10);
csys = ((csyw + 16'sd512) >>> 10);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd3;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd3;
end
csd = (czw >= 16'sd0);
csxs = ((csxw + 16'sd1024) >>> 11);
csys = ((csyw + 16'sd1024) >>> 11);
if (csd) begin
    csxw = csxw - csys; csyw = csyw + csxs; czw = czw - 16'sd1;
end else begin
    csxw = csxw + csys; csyw = csyw - csxs; czw = czw + 16'sd1;
end
csd = (czw >= 16'sd0);
csxse = csxw;
csxpr = (csxse <<< 1) + -(csxse <<< 3) + -(csxse <<< 6) + -(csxse <<< 9) + (csxse <<< 12) + (csxse <<< 14);
csyse = csyw;
csypr = (csyse <<< 1) + -(csyse <<< 3) + -(csyse <<< 6) + -(csyse <<< 9) + (csyse <<< 12) + (csyse <<< 14);
csscos = (csxpr + 32'sd16384) >>> 15;
csssin = (csypr + 32'sd16384) >>> 15;
csoc = csro ? csxw[11:0] : csscos;
csos = csro ? csyw[11:0] : csssin;
if(a[31:14]!=0 || b[31:16]!=0 || b[14]!=0 || (csck && (csstep > cslim))) f=1'b1;
else begin
    state_n[13:0] = csacc;
    r = {czw[15], csfold, csacc[13], cswrap, csck, csro, cshd, csres, csos, csoc};
    x = {cswrap, csm, csp, csq, czw[13:0], csacc};
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
