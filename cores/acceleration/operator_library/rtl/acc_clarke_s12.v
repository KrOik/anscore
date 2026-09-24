// Authored kernel. See ip/clarke_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_clarke_s12 (
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
reg [11:0] cla, clb, clc, cld;
localparam signed [11:0] CL_K = 12'sd1182;
localparam integer CL_SHIFT = 11;
reg signed [13:0] ia, ib, ic, s1v, s2v, b1v, b2v, dlt;
reg [13:0] adv;
reg enchk, viol;
wire [23:0] clp1_raw;
wire signed [23:0] clp1 = $signed(clp1_raw);
MULT12X12 u_clp1 (.DOUT(clp1_raw), .A(cla), .B(clb), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] clp2_raw;
wire signed [23:0] clp2 = $signed(clp2_raw);
MULT12X12 u_clp2 (.DOUT(clp2_raw), .A(clc), .B(cld), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ia = {{4{a[9]}}, a[9:0]};
ib = {{4{a[19]}}, a[19:10]};
ic = {{4{b[9]}}, b[9:0]};
s1v = ia + ib + ib;
s2v = ib - ic;
cla = s1v[11:0];
clb = CL_K;
clc = s2v[11:0];
cld = CL_K;
swide = clp1 + 24'sd1024;
b1v = swide >>> CL_SHIFT;
swide = clp2 + 24'sd1024;
b2v = swide >>> CL_SHIFT;
dlt = b1v - b2v;
adv = dlt < 14'sd0 ? -dlt : dlt;
enchk = c[31];
viol = enchk && (adv > {6'd0, c[7:0]});
if(a[31:20]!=0 || b[31:10]!=0 || c[30:8]!=0) f=1'b1;
else begin
    r = {8'd0, b1v[11:0], ia[11:0]};
    x = {6'd0, viol, enchk, adv[11:0], b2v[11:0]};
    f = viol;
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
