// Authored kernel. See ip/chroma_key/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_chroma_key (
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
    if(c[30:26]!=0) begin
    f=1'b1; r=0; x=0; state_n=state_r;
end else if(c[25] && (c[7:0]<32'd16 || c[7:0]>32'd240 ||
                      c[15:8]<32'd16 || c[15:8]>32'd240)) begin
    f=1'b1; r=0; x=0; state_n=state_r;
end else begin
    if(c[31]) begin
        state_n=0; state_n[7:0]=8'd128; state_n[15:8]=8'd128;
    end
    if(c[25]) begin
        state_n[7:0]=c[7:0]; state_n[15:8]=c[15:8];
        state_n[19:16]=c[19:16]; state_n[23:20]=c[23:20]; state_n[24]=c[24];
    end
    state_n[31:25]=state_n[31:25]+7'd1;
    pa=state_n[7:0];
    pb=state_n[15:8];
    sh=state_n[24];
    if(sh) begin
        pc=state_n[19:16]<<5; ph=state_n[23:20]<<1;
    end else begin
        pc=state_n[19:16]<<4; ph=state_n[23:20];
    end
    ext=pc+ph;
    mask=0;
    for(lane=0;lane<4;lane=lane+1) begin
        temp={24'd0,a[(lane<<3)+:8]};
        pl={24'd0,b[(lane<<3)+:8]};
        if(temp<32'd16 || temp>32'd240 || pl<32'd16 || pl>32'd240) x[27]=1'b1;
        if(temp>pa) temp=temp-pa; else temp=pa-temp;
        if(pl>pb) pl=pl-pb; else pl=pb-pl;
        if(temp==pl) r[23]=1'b1;
        if(sh) wide2=temp+pl; else wide2=(pl>temp) ? pl : temp;
        if(wide2>mask) mask=wide2[31:0];
        if(wide2<=pc) begin
            r[lane]=1'b1; r[4+lane]=1'b1; i=i+1; j=2;
        end else if(wide2<=ext) begin
            r[lane]=1'b1; r[8+lane]=1'b1; i=i+1; if(j<1) j=1;
        end else r[12+lane]=1'b1;
    end
    r[19:16]=i; r[21:20]=j; r[22]=sh;
    r[31:24]=mask;
    x[7:0]=state_n[7:0];
    x[15:8]=state_n[15:8];
    x[19:16]=state_n[19:16]; x[23:20]=state_n[23:20];
    x[24]=c[25]; x[25]=c[31]; x[26]=(r[3:0]!=0);
    x[28]=(state_n[19:16]==0);
    x[31:29]=state_n[27:25];
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
