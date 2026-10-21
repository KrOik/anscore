// Authored kernel. See ip/pkt_field_extract_variable/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pkt_field_extract_variable (
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
reg [63:0] pair, wv64, big;
reg [8:0] pos, pk, lanemax;
reg [9:0] tot;
reg [3:0] wv, base;
reg [7:0] lp;
reg bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    pair = {b, a};
base = c[3:0];
lanemax = {1'b0, c[31:24]};
if (lanemax == 9'd0) lanemax = 9'd1;
pos = {5'd0, base};
tot = {5'd0, base};
lp = 8'd0;
bad = 1'b0;
for (lane = 0; lane < 4; lane = lane + 1) begin
    if (c[((lane << 2) + 4) +: 4] > 4'd8) bad = 1'b1;
end
if (bad) begin
    f = 1'b1;
    for (lane = 0; lane < 4; lane = lane + 1) begin
        if (c[((lane << 2) + 4) +: 4] > 4'd8) x[12+lane] = 1'b1;
    end
end else begin
    for (lane = 0; lane < 4; lane = lane + 1) begin
        wv = c[((lane << 2) + 4) +: 4];
        pk = pos;
        if (wv == 4'd0) begin
            x[8+lane] = 1'b1;
        end else if (pk >= lanemax || (pk + {5'd0, wv}) > lanemax ||
                     (pk + {5'd0, wv}) > 9'd64) begin
            x[4+lane] = 1'b1; f = 1'b1;
        end else begin
            if (pk < 9'd32 && (pk + {5'd0, wv}) > 9'd32) x[lane] = 1'b1;
            wv64 = pair >> pk;
            big = {65'd1} << wv;
            r[(lane << 3) +: 8] = wv64 & (big[63:0] - 64'd1);
            tot = tot + {5'd0, wv};
            lp = pk[7:0];
        end
        pos = pk + {5'd0, wv};
    end
    x[23:16] = tot[7:0];
    x[31:24] = lp;
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
