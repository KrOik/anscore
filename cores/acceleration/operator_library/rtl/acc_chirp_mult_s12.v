// Authored kernel. See ip/chirp_mult_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_chirp_mult_s12 (
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
reg signed [11:0] q_xr, q_xi, q_cs, q_sn, q_wr, q_wi;
reg signed [13:0] q_wr14, q_wi14;
reg [1:0] q_q;
reg [3:0] q_l;
reg q_cj, q_swap, q_nre, q_nim, q_clip, q_axis;
reg q_rsat, q_isat;
wire [23:0] q_p0_raw;
wire signed [23:0] q_p0 = $signed(q_p0_raw);
MULT12X12 u_q_p0 (.DOUT(q_p0_raw), .A(q_xr), .B(q_wr), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p1_raw;
wire signed [23:0] q_p1 = $signed(q_p1_raw);
MULT12X12 u_q_p1 (.DOUT(q_p1_raw), .A(q_xi), .B(q_wi), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p2_raw;
wire signed [23:0] q_p2 = $signed(q_p2_raw);
MULT12X12 u_q_p2 (.DOUT(q_p2_raw), .A(q_xi), .B(q_wr), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] q_p3_raw;
wire signed [23:0] q_p3 = $signed(q_p3_raw);
MULT12X12 u_q_p3 (.DOUT(q_p3_raw), .A(q_xr), .B(q_wi), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    q_xr=a[11:0]; q_xi=a[23:12]; q_cs=b[11:0]; q_sn=b[23:12];
q_l=c[3:0]; q_q=c[5:4]; q_cj=c[6];
q_clip=1'b0; q_axis=1'b0; q_rsat=1'b0; q_isat=1'b0;
if(a[31:24]!=0 || b[31:24]!=0 || c[31:7]!=0 || q_l<4'd2 || q_l>4'd12)
    f=1'b1;
else begin
    q_swap=q_q[0]; q_nre=q_q[0]^q_q[1]; q_nim=q_q[1];
    if(q_swap) begin q_wr14=q_sn; q_wi14=q_cs; end
    else begin q_wr14=q_cs; q_wi14=q_sn; end
    if(q_nre) q_wr14=-q_wr14;
    if(q_nim) q_wi14=-q_wi14;
    if(q_cj) q_wi14=-q_wi14;
    if(q_wr14>14'sd2047) begin q_wr=12'h7ff; q_clip=1'b1; end
    else if(q_wr14<-14'sd2048) begin q_wr=12'h800; q_clip=1'b1; end
    else q_wr=q_wr14[11:0];
    if(q_wi14>14'sd2047) begin q_wi=12'h7ff; q_clip=1'b1; end
    else if(q_wi14<-14'sd2048) begin q_wi=12'h800; q_clip=1'b1; end
    else q_wi=q_wi14[11:0];
    q_axis=(q_wr==12'sd0) || (q_wi==12'sd0);
    swide=q_p0-q_p1; swide=swide+64'sd512; swide=swide>>>10;
    if(swide>64'sd2047) begin q_rsat=1'b1; swide=64'sd2047; end
    else if(swide<-64'sd2048) begin q_rsat=1'b1; swide=-64'sd2048; end
    r[11:0]=swide[11:0];
    swide2=q_p2+q_p3; swide2=swide2+64'sd512; swide2=swide2>>>10;
    if(swide2>64'sd2047) begin q_isat=1'b1; swide2=64'sd2047; end
    else if(swide2<-64'sd2048) begin q_isat=1'b1; swide2=-64'sd2048; end
    r[23:12]=swide2[11:0];
    r[24]=q_rsat; r[25]=q_isat; r[26]=q_clip; r[27]=q_cj;
    r[29:28]=q_q; r[30]=q_axis; r[31]=1'b0;
    x[11:0]=q_wr; x[23:12]=q_wi; x[27:24]=q_l; x[31:28]=4'd0;
    f=q_rsat|q_isat|q_clip;
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
