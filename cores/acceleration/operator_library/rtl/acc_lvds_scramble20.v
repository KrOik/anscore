// Authored kernel. See ip/lvds_scramble20/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_lvds_scramble20 (
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

assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(a[31:21]!=0 || c[30:2]!=0) begin
    f=1'b1; r=0; x=0; state_n=state_r;
end else if(c[31] || c[1]) begin
    if(c[31]) state_n=0;
    state_n[19:0]=20'hFFFFF;
    state_n[44]=1'b1;
    r[19:0]=20'hFFFFF;
    r[20]=a[20];
    x[0]=c[0]; x[1]=1'b1; x[2]=1'b1; x[3]=c[31];
    x[13:6]=state_n[27:20]; x[21:14]=state_n[35:28];
    x[29:22]=state_n[43:36]; x[30]=1'b1;
end else if(!state_r[44]) begin
    f=1'b1; r=0; x=0; state_n=state_r;
end else begin
    // 20 feed-forward stages: stage i taps only bits below i.
    ph[0]=a[0]^state_r[17]^state_r[14]^state_r[4]^state_r[0];
    ph[1]=a[1]^state_r[18]^state_r[15]^state_r[5]^state_r[1];
    ph[2]=a[2]^state_r[19]^state_r[16]^state_r[6]^state_r[2];
    ph[3]=a[3]^(c[0] ? a[0] : ph[0])^state_r[17]^state_r[7]^state_r[3];
    ph[4]=a[4]^(c[0] ? a[1] : ph[1])^state_r[18]^state_r[8]^state_r[4];
    ph[5]=a[5]^(c[0] ? a[2] : ph[2])^state_r[19]^state_r[9]^state_r[5];
    ph[6]=a[6]^(c[0] ? a[3] : ph[3])^(c[0] ? a[0] : ph[0])^state_r[10]^state_r[6];
    ph[7]=a[7]^(c[0] ? a[4] : ph[4])^(c[0] ? a[1] : ph[1])^state_r[11]^state_r[7];
    ph[8]=a[8]^(c[0] ? a[5] : ph[5])^(c[0] ? a[2] : ph[2])^state_r[12]^state_r[8];
    ph[9]=a[9]^(c[0] ? a[6] : ph[6])^(c[0] ? a[3] : ph[3])^state_r[13]^state_r[9];
    ph[10]=a[10]^(c[0] ? a[7] : ph[7])^(c[0] ? a[4] : ph[4])^state_r[14]^state_r[10];
    ph[11]=a[11]^(c[0] ? a[8] : ph[8])^(c[0] ? a[5] : ph[5])^state_r[15]^state_r[11];
    ph[12]=a[12]^(c[0] ? a[9] : ph[9])^(c[0] ? a[6] : ph[6])^state_r[16]^state_r[12];
    ph[13]=a[13]^(c[0] ? a[10] : ph[10])^(c[0] ? a[7] : ph[7])^state_r[17]^state_r[13];
    ph[14]=a[14]^(c[0] ? a[11] : ph[11])^(c[0] ? a[8] : ph[8])^state_r[18]^state_r[14];
    ph[15]=a[15]^(c[0] ? a[12] : ph[12])^(c[0] ? a[9] : ph[9])^state_r[19]^state_r[15];
    ph[16]=a[16]^(c[0] ? a[13] : ph[13])^(c[0] ? a[10] : ph[10])^(c[0] ? a[0] : ph[0])^state_r[16];
    ph[17]=a[17]^(c[0] ? a[14] : ph[14])^(c[0] ? a[11] : ph[11])^(c[0] ? a[1] : ph[1])^state_r[17];
    ph[18]=a[18]^(c[0] ? a[15] : ph[15])^(c[0] ? a[12] : ph[12])^(c[0] ? a[2] : ph[2])^state_r[18];
    ph[19]=a[19]^(c[0] ? a[16] : ph[16])^(c[0] ? a[13] : ph[13])^(c[0] ? a[3] : ph[3])^state_r[19];
    wide2=c[0] ? {44'd0,a[19:0]} : {44'd0,ph[19:0]};
    for(lane=0;lane<20;lane=lane+1) if(wide2[lane]) i=i+1;
    for(lane=1;lane<20;lane=lane+1) if(wide2[lane]!=wide2[lane-1]) j=j+1;
    mask=(wide2[0]!=state_r[19]);
    state_n[19:0]=c[0] ? a[19:0] : ph[19:0];
    state_n[27:20]=state_r[27:20]+8'd1;
    state_n[35:28]=state_r[35:28]+i;
    state_n[43:36]=state_r[43:36]+j;
    r[19:0]=ph[19:0]; r[20]=a[20]; r[25:21]=i; r[30:26]=j;
    if(j==0 && !mask) r[31]=1'b1;
    x[0]=c[0]; x[1]=1'b1; x[5]=mask;
    if(i<7 || i>13) x[4]=1'b1;
    if(state_n[19:0]==20'hFFFFF) x[30]=1'b1;
    x[13:6]=state_n[27:20]; x[21:14]=state_n[35:28];
    x[29:22]=state_n[43:36];
    if(wide2=={44'd0,state_r[19:0]}) x[31]=1'b1;
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
