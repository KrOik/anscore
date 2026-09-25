// Authored kernel. See ip/memprot_scrub_cursor_window/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_memprot_scrub_cursor_window (
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
    mask = {22'd0, state_r[9:0]};
pb = {26'd0, state_r[15:10]};
pa = {26'd0, b[5:0]};
ph = 32'd0;
for(i=0; i<32; i=i+1) if(a[i]) ph = ph + 32'd1;
if(c[31]) begin
    mask = {22'd0, c[9:5], 5'd0};
    pb = 32'd0;
end
pl = 32'd0;
if(b[5:0] > 6'd32) begin
    pl[1] = 1'b1;
    pa = 32'd32;
end
if(pa > 32'd32) pa = 32'd32;
temp = pb + ph;
lane = (pa > pb) ? (pa - pb) : 32'd0;
for(i=0; i<32; i=i+1) if(a[i] && lane > 0) begin
    r[i] = 1'b1;
    lane = lane - 32'd1;
end
pc = (pa > temp) ? temp : pa;
idx = temp - pc;
if(idx > 32'd63) begin
    idx = 32'd63;
    pl[0] = 1'b1;
end
if(idx > b[13:8]) pl[2] = 1'b1;
ext = mask + 33'd32;
pl[4] = (ext > 33'd1023);
wide = c[31] ? 64'd0 : {40'd0, state_r[47:24]};
wide = wide + {32'd0, ph};
if(wide > 64'h00FFFFFF) wide = 64'h00FFFFFF;
state_n[47:24] = wide[23:0];
wide2 = c[31] ? 64'd0 : {40'd0, state_r[71:48]};
wide2 = wide2 + {32'd0, pc};
if(wide2 > 64'h00FFFFFF) wide2 = 64'h00FFFFFF;
state_n[71:48] = wide2[23:0];
wide = (state_n[47:24] > state_n[71:48]) ?
       ({40'd0, state_n[47:24]} - {40'd0, state_n[71:48]}) : 64'd0;
if(wide > 64'd1024) pl[3] = 1'b1;
pb = c[31] ? {24'd0, c[23:16]} : {24'd0, state_r[23:16]};
state_n[23:16] = pb[7:0];
if(pl[4] && pb != 32'd255) begin
    pb = pb + 32'd1;
    state_n[23:16] = pb[7:0];
end
state_n[9:0] = pl[4] ? 10'd0 : ext[9:0];
state_n[15:10] = idx;
x[9:0] = state_n[9:0];
x[15:10] = state_n[15:10];
x[16] = pl[4];
x[17] = (a & ~r) != 32'd0;
x[18] = c[31];
x[19] = pl[0];
x[20] = pl[1];
x[21] = pl[2];
x[22] = pl[3];
x[23] = temp > pa;
x[31:24] = state_n[23:16];
f = pl[1] || pl[2] || pl[3];
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
