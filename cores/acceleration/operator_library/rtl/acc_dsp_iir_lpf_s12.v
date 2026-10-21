// Authored kernel. See ip/dsp_iir_lpf_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_dsp_iir_lpf_s12 (
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
reg [11:0] lp_a, lp_b;
reg signed [11:0] xs, yold, ie, ig;
reg signed [12:0] ds;
reg signed [13:0] yn;
wire [23:0] lp_raw;
wire signed [23:0] lp = $signed(lp_raw);
MULT12X12 u_lp (.DOUT(lp_raw), .A(lp_a), .B(lp_b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    xs={a[10], a[10:0]};
yold = c[31] ? xs : {state_r[10], state_r[10:0]};
ie = xs - yold;
ig = {1'b0, b[10:0]};
lp_a=ie; lp_b=ig;
ds = (lp + 24'sd512) >>> 10;
yn = yold + ds;
if(yn > 13'sd1023) begin r={21'd0, 11'h3ff}; x[12]=1'b1; f=1'b1; state_n={245'd0, 11'h3ff}; end
else if(yn < -13'sd1024) begin r={21'd0, 11'h400}; x[13]=1'b1; f=1'b1; state_n={245'd0, 11'h400}; end
else begin r={21'd0, yn[10:0]}; state_n={245'd0, yn[10:0]}; end
x[11:0]=ie;
x[26:14]=ds;
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
