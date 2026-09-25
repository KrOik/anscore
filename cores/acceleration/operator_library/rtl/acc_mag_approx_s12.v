// Authored kernel. See ip/mag_approx_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_mag_approx_s12 (
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
reg signed [11:0] q_re, q_im;
reg [11:0] q_ar, q_ai, q_hi, q_lo;
reg [12:0] q_t0, q_t1, q_t2, q_t3, q_m, q_up;
reg [3:0] q_tier;
reg q_swap, q_sre, q_sim, q_zero, q_equal, q_over;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    q_re=a[11:0]; q_im=a[23:12]; q_tier=c[3:0];
q_swap=1'b0; q_sre=1'b0; q_sim=1'b0; q_zero=1'b0; q_equal=1'b0; q_over=1'b0;
if(a[31:24]!=0 || b!=32'd0 || c[31:4]!=0 || q_tier>4'd3) f=1'b1;
else begin
    q_sre=q_re[11]; q_sim=q_im[11];
    q_ar=q_re[11] ? (~q_re + 12'd1) : q_re;
    q_ai=q_im[11] ? (~q_im + 12'd1) : q_im;
    if(q_ar>=q_ai) begin q_hi=q_ar; q_lo=q_ai; q_swap=1'b0; end
    else begin q_hi=q_ai; q_lo=q_ar; q_swap=1'b1; end
    q_zero=(q_ar==12'd0 && q_ai==12'd0);
    q_equal=(q_ar==q_ai);
    q_t0=q_hi+(q_lo>>1);
    q_t1=q_hi+(q_lo>>1)-(q_lo>>3);
    q_t2=q_hi+(q_lo>>2);
    q_t3=q_hi+(q_lo>>2)+(q_lo>>4);
    case(q_tier)
        4'd0: q_m=q_t0;
        4'd1: q_m=q_t1;
        4'd2: q_m=q_t2;
        default: q_m=q_t3;
    endcase
    q_up=q_hi+(q_lo>>1);
    q_over=(q_m>13'd4095);
    r[11:0]=q_m[11:0]; r[12]=q_swap; r[13]=q_sre; r[14]=q_sim;
    r[15]=q_zero; r[16]=q_equal; r[18:17]=q_tier[1:0]; r[31:19]=13'd0;
    x[11:0]=q_hi; x[23:12]=q_up[11:0]; x[24]=!q_over;
    x[26:25]=q_tier[1:0]; x[31:27]=5'd0;
    f=q_over;
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
