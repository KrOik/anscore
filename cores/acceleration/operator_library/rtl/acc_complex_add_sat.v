// Authored kernel. See ip/complex_add_sat/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_complex_add_sat (
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
reg signed [11:0] q_xr, q_xi, q_yr, q_yi, q_or, q_oi, q_pr, q_pi;
reg signed [13:0] q_yr14, q_yi14, q_zr, q_zi, q_sr, q_si, q_dr, q_di;
reg [3:0] q_k;
reg q_ar, q_ai, q_br, q_bi;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    q_xr=a[11:0]; q_xi=a[23:12]; q_yr=b[11:0]; q_yi=b[23:12]; q_k=c[3:0];
q_ar=1'b0; q_ai=1'b0; q_br=1'b0; q_bi=1'b0;
if(a[31:24]!=0 || b[31:24]!=0 || c[31:4]!=0) f=1'b1;
else begin
    q_yr14=q_yr; q_yi14=q_yi;
    q_zr=q_yr14>>>q_k; q_zi=q_yi14>>>q_k;
    q_sr=q_xr+q_zr; q_si=q_xi+q_zi;
    q_dr=q_xr-q_zr; q_di=q_xi-q_zi;
    if(q_sr>14'sd2047) begin q_or=12'h7ff; q_ar=1'b1; end
    else if(q_sr<-14'sd2048) begin q_or=12'h800; q_ar=1'b1; end
    else q_or=q_sr[11:0];
    if(q_si>14'sd2047) begin q_oi=12'h7ff; q_ai=1'b1; end
    else if(q_si<-14'sd2048) begin q_oi=12'h800; q_ai=1'b1; end
    else q_oi=q_si[11:0];
    if(q_dr>14'sd2047) begin q_pr=12'h7ff; q_br=1'b1; end
    else if(q_dr<-14'sd2048) begin q_pr=12'h800; q_br=1'b1; end
    else q_pr=q_dr[11:0];
    if(q_di>14'sd2047) begin q_pi=12'h7ff; q_bi=1'b1; end
    else if(q_di<-14'sd2048) begin q_pi=12'h800; q_bi=1'b1; end
    else q_pi=q_di[11:0];
    r[11:0]=q_or; r[23:12]=q_oi; r[24]=q_ar; r[25]=q_ai;
    r[27:26]=2'd0; r[31:28]=q_k;
    x[11:0]=q_pr; x[23:12]=q_pi; x[24]=q_br; x[25]=q_bi;
    x[27:26]=2'd0; x[31:28]=q_k;
    f=q_ar|q_ai|q_br|q_bi;
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
