// Authored kernel. See ip/ipi_pid_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ipi_pid_s12 (
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
reg [11:0] pr1a, pr1b, pr2a, pr2b, pr3a, pr3b;
reg signed [13:0] ev, ffv, kp, ki, i0v, epv, dev, dec, irv, itv, icv;
reg signed [13:0] hiv, lov;
reg signed [31:0] pv, iv, dv, outv, outc;
reg [11:0] kd;
reg [3:0] sft, pfl;
reg wind;
wire [23:0] pr1_raw;
wire signed [23:0] pr1 = $signed(pr1_raw);
MULT12X12 u_pr1 (.DOUT(pr1_raw), .A(pr1a), .B(pr1b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] pr2_raw;
wire signed [23:0] pr2 = $signed(pr2_raw);
MULT12X12 u_pr2 (.DOUT(pr2_raw), .A(pr2a), .B(pr2b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] pr3_raw;
wire signed [23:0] pr3 = $signed(pr3_raw);
MULT12X12 u_pr3 (.DOUT(pr3_raw), .A(pr3a), .B(pr3b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ev = $signed(a[11:0]);
ffv = $signed(a[23:12]);
sft = c[3:0];
kp = $signed(b[11:0]);
ki = $signed(b[23:12]);
kd = {4'd0, b[31:24]};
if(c[31]) begin i0v = 14'sd0; epv = 14'sd0; end
else begin
    i0v = $signed(state_r[11:0]);
    epv = $signed(state_r[23:12]);
end
dev = ev - epv;
if(dev > 14'sd2047)      begin dec = 14'sd2047;  pfl[0] = 1'b1; end
else if(dev < -14'sd2048) begin dec = -14'sd2048; pfl[0] = 1'b1; end
else                      begin dec = dev[13:0];  pfl[0] = 1'b0; end
irv = i0v + ev;
if(c[30])                    begin itv = i0v;      pfl[1] = 1'b0; end
else if(irv > 14'sd2047)     begin itv = 14'sd2047;  pfl[1] = 1'b1; end
else if(irv < -14'sd2048)    begin itv = -14'sd2048; pfl[1] = 1'b1; end
else                         begin itv = irv[13:0];  pfl[1] = 1'b0; end
pr1a = ev[11:0];
pr1b = kp[11:0];
pr2a = itv[11:0];
pr2b = ki[11:0];
pr3a = dec[11:0];
pr3b = kd[11:0];
swide = pr1 + (sft == 4'd0 ? 64'sd0 : (64'sd1 <<< (sft - 4'd1)));
pv = swide >>> sft;
swide = pr2 + (sft == 4'd0 ? 64'sd0 : (64'sd1 <<< (sft - 4'd1)));
iv = swide >>> sft;
swide = pr3 + (sft == 4'd0 ? 64'sd0 : (64'sd1 <<< (sft - 4'd1)));
dv = swide >>> sft;
if(c[29]) begin hiv = 14'sd1023; lov = -14'sd1024; end
else      begin hiv = 14'sd2047; lov = -14'sd2048; end
outv = pv + iv + dv + ffv;
if(outv > hiv)      begin outc = hiv;  pfl[2] = 1'b1; pfl[3] = 1'b0; end
else if(outv < lov) begin outc = lov;  pfl[2] = 1'b0; pfl[3] = 1'b1; end
else                begin outc = outv; pfl[2] = 1'b0; pfl[3] = 1'b0; end
wind = (pfl[2] && ev > 14'sd0) || (pfl[3] && ev < 14'sd0);
icv = (wind && !c[30]) ? i0v : itv;
if(a[31:24]!=0 || c[28:4]!=0) f=1'b1;
else begin
    state_n[11:0] = icv[11:0];
    state_n[23:12] = ev[11:0];
    r = {8'd0, sft, c[29], c[31], c[30], wind, pfl[0], pfl[1], pfl[3], pfl[2], outc[11:0]};
    x = {6'd0, icv[11:0], outv[13:0]};
    f = pfl[2] || pfl[3] || pfl[1];
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
