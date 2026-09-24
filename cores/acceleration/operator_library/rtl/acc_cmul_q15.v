// Authored kernel. See ip/cmul_q15/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_cmul_q15 (
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
reg signed [11:0] q_zr, q_zi, q_wr, q_wi, q_su, q_sw;
reg signed [12:0] q_u13, q_w13;
reg q_cj, q_uclip, q_wclip, q_rsat, q_isat;
wire [23:0] q_p1_raw;
wire signed [23:0] q_p1 = $signed(q_p1_raw);
MULT12X12 u_q_p1 (.DOUT(q_p1_raw), .A(q_zr), .B(q_wr), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p2_raw;
wire signed [23:0] q_p2 = $signed(q_p2_raw);
MULT12X12 u_q_p2 (.DOUT(q_p2_raw), .A(q_zi), .B(q_wi), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p3_raw;
wire signed [23:0] q_p3 = $signed(q_p3_raw);
MULT12X12 u_q_p3 (.DOUT(q_p3_raw), .A(q_su), .B(q_sw), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    q_zr=a[11:0]; q_zi=a[23:12]; q_wr=b[11:0]; q_wi=b[23:12]; q_cj=c[0];
q_uclip=1'b0; q_wclip=1'b0; q_rsat=1'b0; q_isat=1'b0;
if(a[31:24]!=0 || b[31:24]!=0 || c[31:1]!=0) f=1'b1;
else begin
    q_u13=q_zr+q_zi;
    if(q_u13>13'sd2047) begin q_su=12'h7ff; q_uclip=1'b1; end
    else if(q_u13<-13'sd2048) begin q_su=12'h800; q_uclip=1'b1; end
    else q_su=q_u13[11:0];
    q_w13=q_wr+q_wi;
    if(q_w13>13'sd2047) begin q_sw=12'h7ff; q_wclip=1'b1; end
    else if(q_w13<-13'sd2048) begin q_sw=12'h800; q_wclip=1'b1; end
    else q_sw=q_w13[11:0];
    swide=q_p1-q_p2; swide=swide+64'sd512; swide=swide>>>10;
    if(swide>64'sd2047) begin q_rsat=1'b1; swide=64'sd2047; end
    else if(swide<-64'sd2048) begin q_rsat=1'b1; swide=-64'sd2048; end
    r[11:0]=swide[11:0];
    swide2=q_p3-q_p1; swide2=swide2-q_p2; swide2=swide2+64'sd512;
    swide2=swide2>>>10;
    if(q_cj) swide2=-swide2;
    if(swide2>64'sd2047) begin q_isat=1'b1; swide2=64'sd2047; end
    else if(swide2<-64'sd2048) begin q_isat=1'b1; swide2=-64'sd2048; end
    r[23:12]=swide2[11:0];
    r[24]=q_rsat; r[25]=q_isat; r[26]=q_uclip; r[27]=q_wclip;
    r[31:28]=4'd0;
    x[11:0]=q_su; x[23:12]=q_sw; x[24]=q_cj; x[31:25]=7'd0;
    f=q_rsat|q_isat|q_uclip|q_wclip;
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
