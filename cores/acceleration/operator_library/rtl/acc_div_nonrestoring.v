// Authored kernel. See ip/div_nonrestoring/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_div_nonrestoring (
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
reg signed [34:0] dr, dmb, dm, dn, drn, dds2;
reg [34:0] dmbits;
reg [33:0] dds;
reg [31:0] ddn, dq, dqn;
reg [5:0] dcnt, dcntn;
reg dsgn, dsgnn, drst, drstn, dhold, dbit, dbig;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    dr=$signed(state_r[34:0]); dq=state_r[66:35];
dds=state_r[100:67]; ddn=state_r[132:101]; dcnt=state_r[138:133];
dsgn=state_r[139]; drst=state_r[140];
drn=dr; dqn=dq; dcntn=dcnt; dsgnn=dsgn; drstn=drst; dds2=4'd0;
dhold=1'b0; dbit=1'b0; dbig=1'b0; dm=dr; dn=dr;
if(c[31]) begin
    if(b==32'd0 || (a==32'h80000000 && b==32'hffffffff)) f=1'b1;
    else begin
        dds=b[31] ? (({2'b0,~b})+34'd1) : {2'b0,b};
        ddn=a[31] ? ((~a)+32'd1) : a;
        dsgnn=a[31]^b[31]; drn=35'sd0; dqn=32'd0; dcntn=6'd0;
        drstn=1'b0;
    end
end else if(dcnt==6'd33) dhold=1'b1;
else begin
    dds2={1'b0,dds};
    if(dcnt==6'd32) begin
        if(dr<0) begin drn=dr+dds2; drstn=1'b1; end
        dcntn=6'd33; dqn=dq;
      end else begin
        sh=31-dcnt;
        dbit=ddn[sh];
        dmbits=(dr<<<1)|{34'd0,dbit};
        dm=$signed(dmbits);
        dn=(dm>=0) ? (dm-dds2) : (dm+dds2);
        drn=dn; dqn={dq[30:0], (dn>=0)}; dcntn=dcnt+6'd1;
    end
end
if(!f) begin
    r=dsgnn ? (~dqn+32'd1) : dqn;
    x[5:0]=dcntn; x[6]=(dcntn==6'd33); x[7]=dsgnn; x[8]=drstn;
    x[9]=(dds>34'd2147483647); x[10]=dbit;
    x[31:11]=drn[20:0];
    state_n={115'd0, drstn, dsgnn, dcntn, ddn, dds, dqn, drn};
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
