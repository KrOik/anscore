// Authored kernel. See ip/inv_park_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_inv_park_s12 (
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
// Image generated from the family model; read combinationally here.
reg [23:0] sincos [0:255];
initial $readmemh("tables/inv_park_s12_sincos.mem", sincos);
reg [11:0] pk1a, pk1b, pk2a, pk2b, pk3a, pk3b;
reg signed [13:0] av, bv, ai, bi, ccs, snx, nsx, abv, csd;
reg signed [13:0] o1v, o2v, m1v, m2v;
reg [3:0] pfl;
reg [7:0] pth;
reg [23:0] pw;
wire [23:0] pk1_raw;
wire signed [23:0] pk1 = $signed(pk1_raw);
MULT12X12 u_pk1 (.DOUT(pk1_raw), .A(pk1a), .B(pk1b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] pk2_raw;
wire signed [23:0] pk2 = $signed(pk2_raw);
MULT12X12 u_pk2 (.DOUT(pk2_raw), .A(pk2a), .B(pk2b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] pk3_raw;
wire signed [23:0] pk3 = $signed(pk3_raw);
MULT12X12 u_pk3 (.DOUT(pk3_raw), .A(pk3a), .B(pk3b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    av = $signed(a[11:0]);
bv = $signed(b[11:0]);
pth = c[7:0];
pw = sincos[pth];
ccs = $signed(pw[23:12]);
snx = $signed(pw[11:0]);
if(av > 14'sd1023)      begin ai = 14'sd1023;  pfl[0] = 1'b1; end
else if(av < -14'sd1024) begin ai = -14'sd1024; pfl[0] = 1'b1; end
else                    begin ai = av;         pfl[0] = 1'b0; end
if(bv > 14'sd1023)      begin bi = 14'sd1023;  pfl[1] = 1'b1; end
else if(bv < -14'sd1024) begin bi = -14'sd1024; pfl[1] = 1'b1; end
else                    begin bi = bv;         pfl[1] = 1'b0; end
nsx = snx;
abv = ai + bi;
csd = ccs + snx;
pk1a = ai[11:0];
pk1b = ccs[11:0];
pk2a = bi[11:0];
pk2b = nsx[11:0];
pk3a = abv[11:0];
pk3b = csd[11:0];
swide = pk1 - pk2 + 24'sd512;
o1v = swide >>> 10;
swide = pk3 - pk1 - pk2 + 24'sd512;
o2v = swide >>> 10;
m1v = o1v < 14'sd0 ? -o1v : o1v;
m2v = o2v < 14'sd0 ? -o2v : o2v;
pfl[2] = m1v > 14'sd1023;
pfl[3] = m2v > 14'sd1023;
if(c[30:8]!=0) f=1'b1;
else begin
    r = {8'd0, o2v[11:0], o1v[11:0]};
    x = {20'd0, pfl[3], pfl[2], pfl[1], pfl[0], pth};
    f = 1'b0;
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
