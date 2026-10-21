// Authored kernel. See ip/backemf_obs_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_backemf_obs_s12 (
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
reg [11:0] ob1a, ob1b;
reg signed [13:0] vv, ivv, Rv, emf, acc0, accn, lr, spd;
reg signed [31:0] drop, emfr, accw;
reg [3:0] sR, sF, LAM;
reg [1:0] ofl;
reg [7:0] btr0, btr;
wire [23:0] ob1_raw;
wire signed [23:0] ob1 = $signed(ob1_raw);
MULT12X12 u_ob1 (.DOUT(ob1_raw), .A(ob1a), .B(ob1b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    vv = $signed(a[11:0]);
ivv = $signed(a[23:12]);
Rv = $signed(b[11:0]);
sR = c[3:0];
sF = c[7:4];
LAM = c[11:8];
ob1a = ivv[11:0];
ob1b = Rv[11:0];
swide = ob1 + (sR == 4'd0 ? 64'sd0 : (64'sd1 <<< (sR - 4'd1)));
drop = swide >>> sR;
emfr = vv - drop;
if(emfr > 32'sd2047)       begin emf = 14'sd2047;  ofl[0] = 1'b1; end
else if(emfr < -32'sd2048) begin emf = -14'sd2048; ofl[0] = 1'b1; end
else                       begin emf = emfr[13:0]; ofl[0] = 1'b0; end
acc0 = c[31] ? 14'sd0 : $signed(state_r[11:0]);
btr0 = c[31] ? 8'd0 : state_r[19:12];
lr = acc0 >>> LAM;
accw = acc0 + emf - lr;
if(c[30])                    begin accn = acc0;      ofl[1] = 1'b0; end
else if(accw > 32'sd2047)    begin accn = 14'sd2047;  ofl[1] = 1'b1; end
else if(accw < -32'sd2048)   begin accn = -14'sd2048; ofl[1] = 1'b1; end
else                         begin accn = accw[13:0]; ofl[1] = 1'b0; end
swide = accn + (sF == 4'd0 ? 64'sd0 : (64'sd1 <<< (sF - 4'd1)));
spd = swide >>> sF;
btr = (btr0 == 8'hff) ? 8'hff : (btr0 + 8'd1);
if(a[31:24]!=0 || b[31:12]!=0 || c[29:12]!=0) f=1'b1;
else begin
    state_n[11:0] = accn[11:0];
    state_n[19:12] = btr;
    r = {8'd0, sR, LAM, c[31], c[30], ofl[0], ofl[1], spd[11:0]};
    x = {btr, accn[11:0], emf[11:0]};
    f = ofl[0] || ofl[1];
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
