// Authored kernel. See ip/r4_bfly_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_r4_bfly_s12 (
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
reg signed [11:0] q_ur, q_ui, q_vr, q_vi, q_wr, q_wi, q_dr, q_di;
reg signed [12:0] q_pr, q_pi;
reg signed [13:0] q_a0r, q_a0i, q_a2r, q_a2i, q_l1r, q_l1i;
reg q_md, q_sgn, q_cr, q_ci, q_fr, q_fi;
wire [23:0] q_p0_raw;
wire signed [23:0] q_p0 = $signed(q_p0_raw);
MULT12X12 u_q_p0 (.DOUT(q_p0_raw), .A(q_dr), .B(q_wr), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p1_raw;
wire signed [23:0] q_p1 = $signed(q_p1_raw);
MULT12X12 u_q_p1 (.DOUT(q_p1_raw), .A(q_di), .B(q_wi), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p2_raw;
wire signed [23:0] q_p2 = $signed(q_p2_raw);
MULT12X12 u_q_p2 (.DOUT(q_p2_raw), .A(q_di), .B(q_wr), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p3_raw;
wire signed [23:0] q_p3 = $signed(q_p3_raw);
MULT12X12 u_q_p3 (.DOUT(q_p3_raw), .A(q_dr), .B(q_wi), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    q_ur=a[11:0]; q_ui=a[23:12]; q_vr=b[11:0]; q_vi=b[23:12];
q_wr=c[11:0]; q_wi=c[23:12]; q_md=c[24]; q_sgn=c[25];
q_cr=1'b0; q_ci=1'b0; q_fr=1'b0; q_fi=1'b0;
if(a[31:24]!=0 || b[31:24]!=0 || c[31:26]!=0) f=1'b1;
else begin
    if(!q_md) begin
        q_a0r=q_ur+q_vr; q_a0i=q_ui+q_vi;
        q_a2r=q_ur-q_vr; q_a2i=q_ui-q_vi;
        r[13:0]=q_a0r; r[27:14]=q_a0i; r[28]=1'b0; r[29]=1'b0;
        r[30]=q_md; r[31]=q_sgn;
        x[13:0]=q_a2r; x[27:14]=q_a2i; x[28]=1'b0; x[29]=1'b0;
        x[30]=q_md; x[31]=1'b0;
    end else begin
        if(q_sgn) begin q_pr=q_ur-q_vi; q_pi=q_ui+q_vr; end
        else begin q_pr=q_ur+q_vi; q_pi=q_ui-q_vr; end
        if(q_pr>13'sd2047) begin q_dr=12'h7ff; q_cr=1'b1; end
        else if(q_pr<-13'sd2048) begin q_dr=12'h800; q_cr=1'b1; end
        else q_dr=q_pr[11:0];
        if(q_pi>13'sd2047) begin q_di=12'h7ff; q_ci=1'b1; end
        else if(q_pi<-13'sd2048) begin q_di=12'h800; q_ci=1'b1; end
        else q_di=q_pi[11:0];
        swide=q_p0-q_p1; swide=swide+64'sd512; swide=swide>>>10;
        if(swide>64'sd2047) begin q_fr=1'b1; swide=64'sd2047; end
        else if(swide<-64'sd2048) begin q_fr=1'b1; swide=-64'sd2048; end
        q_l1r=swide[13:0];
        swide2=q_p2+q_p3; swide2=swide2+64'sd512; swide2=swide2>>>10;
        if(swide2>64'sd2047) begin q_fi=1'b1; swide2=64'sd2047; end
        else if(swide2<-64'sd2048) begin q_fi=1'b1; swide2=-64'sd2048; end
        q_l1i=swide2[13:0];
        r[13:0]=q_l1r; r[27:14]=q_l1i; r[28]=q_fr; r[29]=q_fi;
        r[30]=q_md; r[31]=q_sgn;
        x[13:0]=q_pr; x[27:14]=q_pi; x[28]=q_cr; x[29]=q_ci;
        x[30]=q_md; x[31]=1'b0;
        f=q_fr|q_fi|q_cr|q_ci;
    end
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
