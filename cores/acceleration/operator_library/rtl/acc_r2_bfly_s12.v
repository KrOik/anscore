// Authored kernel. See ip/r2_bfly_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_r2_bfly_s12 (
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
reg signed [11:0] q_xr, q_xi, q_yr, q_yi, q_dr, q_di, q_gr;
reg signed [12:0] q_sr, q_si, q_dr13, q_di13, q_br, q_bm;
reg signed [25:0] q_rs, q_is;
reg [2:0] q_ax;
reg q_cr, q_ci, q_or, q_oi;
wire [23:0] q_p0_raw;
wire signed [23:0] q_p0 = $signed(q_p0_raw);
MULT12X12 u_q_p0 (.DOUT(q_p0_raw), .A(q_dr), .B(q_gr), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p1_raw;
wire signed [23:0] q_p1 = $signed(q_p1_raw);
MULT12X12 u_q_p1 (.DOUT(q_p1_raw), .A(q_di), .B(q_gr), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    q_xr=a[11:0]; q_xi=a[23:12]; q_yr=b[11:0]; q_yi=b[23:12];
q_gr=c[11:0]; q_ax=c[14:12];
q_sr=q_xr+q_yr; q_si=q_xi+q_yi;
q_dr13=q_xr-q_yr; q_di13=q_xi-q_yi;
q_cr=1'b0; q_ci=1'b0; q_or=1'b0; q_oi=1'b0;
if(a[31:24]!=0 || b[31:24]!=0 || c[31:15]!=0) f=1'b1;
else begin
    case(q_ax)
        3'd0: begin q_br=q_dr13; q_bm=q_di13; end
        3'd1: begin q_br=q_di13; q_bm=-q_dr13; end
        3'd2: begin q_br=-q_dr13; q_bm=-q_di13; end
        default: begin q_br=-q_di13; q_bm=q_dr13; end
    endcase
    if(q_br>13'sd2047) begin q_dr=12'h7ff; q_cr=1'b1; end
    else if(q_br<-13'sd2048) begin q_dr=12'h800; q_cr=1'b1; end
    else q_dr=q_br[11:0];
    if(q_bm>13'sd2047) begin q_di=12'h7ff; q_ci=1'b1; end
    else if(q_bm<-13'sd2048) begin q_di=12'h800; q_ci=1'b1; end
    else q_di=q_bm[11:0];
    swide=q_p0+24'sd512; swide=swide>>>10; q_rs=swide;
    if(q_rs>26'sd2047) begin q_or=1'b1; q_rs=26'sd2047; end
    else if(q_rs<-26'sd2048) begin q_or=1'b1; q_rs=-26'sd2048; end
    else q_rs=q_rs;
    x[11:0]=q_rs[11:0];
    swide=q_p1+24'sd512; swide=swide>>>10; q_is=swide;
    if(q_is>26'sd2047) begin q_oi=1'b1; q_is=26'sd2047; end
    else if(q_is<-26'sd2048) begin q_oi=1'b1; q_is=-26'sd2048; end
    else q_is=q_is;
    x[23:12]=q_is[11:0];
    x[24]=q_or; x[25]=q_oi; x[26]=q_cr|q_ci; x[31:27]=5'd0;
    r[12:0]=q_sr; r[25:13]=q_si; r[26]=q_cr|q_ci; r[28:27]=2'd0;
    r[31:29]=q_ax;
    f=q_or|q_oi|q_cr|q_ci;
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
