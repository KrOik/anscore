// Authored kernel. See ip/memprot_misr32_signature/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_memprot_misr32_signature (
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
    temp = state_r[31:0];
if(c[31]) begin
    r = a;
    state_n[31:0] = a;
    state_n[63:32] = 32'd0;
    state_n[95:64] = a;
    state_n[99:96] = 4'hF;
    state_n[100] = (a == 32'd0);
end else begin
    mask = {temp[30:0], 1'b0};
    if(temp[31]) mask = mask ^ 32'h000000AF;
    r = mask ^ a;
    state_n[31:0] = r;
    if(state_r[63:32] != 32'h0000FFFF) state_n[63:32] = state_r[63:32] + 32'd1;
    state_n[99:96] = state_r[99:96] & ~((a[31:24] != 0) ? 4'h8 : 4'h0) &
                                    ~((a[23:16] != 0) ? 4'h4 : 4'h0) &
                                    ~((a[15:8]  != 0) ? 4'h2 : 4'h0) &
                                    ~((a[7:0]   != 0) ? 4'h1 : 4'h0);
    if(r == 32'd0) state_n[100] = 1'b1;
end
pl = r ^ temp;
for(i=0; i<32; i=i+1) if(pl[i]) sh = sh + 1;
x[5:0] = sh;
x[9:6] = {(a[31:24] != 0), (a[23:16] != 0), (a[15:8] != 0), (a[7:0] != 0)};
x[10] = (r == temp);
x[11] = !c[31] && (state_r[63:32] != 32'd0) && (r == state_r[95:64]);
x[12] = (sh < 16);
x[13] = (r == 32'd0);
x[14] = (c[15:0] != 16'd0);
x[15] = x[14] && (((r ^ b) & {16'd0, c[15:0]}) == 32'd0);
x[16] = (state_n[99:96] != 4'h0);
x[20:17] = state_n[99:96];
x[21] = state_n[100];
if(r == 32'd0) f = 1'b1;
if(x[14] && !x[15]) f = 1'b1;
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
