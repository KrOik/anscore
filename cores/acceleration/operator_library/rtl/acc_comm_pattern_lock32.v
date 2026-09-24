// Authored kernel. See ip/comm_pattern_lock32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_comm_pattern_lock32 (
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
function [5:0] pc32;                       // popcount of a 32-bit word
    input [31:0] v;
    reg [31:0] t;
    begin
        t = v - ((v >> 1) & 32'h55555555);
        t = (t & 32'h33333333) + ((t >> 2) & 32'h33333333);
        t = (t + (t >> 4)) & 32'h0F0F0F0F;
        t = t + (t >> 8);
        t = t + (t >> 16);
        pc32 = t[5:0];
    end
endfunction

function [5:0] tz32;                       // zeros below the lowest set bit, 32 if empty
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        t = v; n = 6'd0;
        if((t & 32'h0000FFFF) == 32'd0) begin n = n + 6'd16; t = t >> 16; end
        if((t & 32'h000000FF) == 32'd0) begin n = n + 6'd8;  t = t >> 8;  end
        if((t & 32'h0000000F) == 32'd0) begin n = n + 6'd4;  t = t >> 4;  end
        if((t & 32'h00000003) == 32'd0) begin n = n + 6'd2;  t = t >> 2;  end
        if((t & 32'h00000001) == 32'd0) begin n = n + 6'd1;  t = t >> 1;  end
        tz32 = (v == 32'd0) ? 6'd32 : n;
    end
endfunction

function [5:0] lz32;                       // zeros above the highest set bit, 32 if empty
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        t = v; n = 6'd0;
        if((t & 32'hFFFF0000) == 32'd0) begin n = n + 6'd16; t = t << 16; end
        if((t & 32'hFF000000) == 32'd0) begin n = n + 6'd8;  t = t << 8;  end
        if((t & 32'hF0000000) == 32'd0) begin n = n + 6'd4;  t = t << 4;  end
        if((t & 32'hC0000000) == 32'd0) begin n = n + 6'd2;  t = t << 2;  end
        if((t & 32'h80000000) == 32'd0) begin n = n + 6'd1;  t = t << 1;  end
        lz32 = (v == 32'd0) ? 6'd32 : n;
    end
endfunction

function [31:0] px32;                      // bit k = XOR of v[k:0], five XOR levels
    input [31:0] v;
    reg [31:0] t;
    begin
        t = v;
        t = t ^ (t << 1);
        t = t ^ (t << 2);
        t = t ^ (t << 4);
        t = t ^ (t << 8);
        t = t ^ (t << 16);
        px32 = t;
    end
endfunction

wire       pl_load = c[31];
wire [31:0] pl_pat = pl_load ? b[31:0] : state_r[63:32];
wire [31:0] pl_old = pl_load ? 32'd0 : state_r[31:0];
wire [63:0] pl_win = {a, pl_old};
wire [32:0] pl_m;
genvar gp;
generate
    for(gp = 0; gp < 33; gp = gp + 1) begin : g_cmp
        assign pl_m[gp] = (pl_win[gp +: 32] == pl_pat);
    end
endgenerate
wire       pl_any = |pl_m;
// Position 32 is the newest of the 33 phases, so it wins over the bitmap.
wire [5:0] pl_newest = pl_m[32] ? 6'd32
                             : (pl_m[31:0] != 32'd0) ? (6'd31 - lz32(pl_m[31:0]))
                                                     : 6'd0;
wire [5:0] pl_cnt6 = pc32(pl_m[31:0]) + {5'd0, pl_m[32]};
wire [4:0] pl_cnt = (pl_cnt6 > 6'd31) ? 5'd31 : pl_cnt6[4:0];
// Distance to the marker for this beat's own word: a near miss says the phase
// hunt is within a few bit slips of lock, which is worth reporting although
// nothing matched, and it is what makes a non-matching beat observable.
wire [5:0] pl_dist = pc32(a ^ pl_pat);
wire       pl_near = (pl_dist != 6'd0) && (pl_dist <= {2'd0, c[11:8]}) && ~pl_any;
wire [3:0] pl_mc = state_r[67:64];
wire [3:0] pl_xc = state_r[71:68];
wire       pl_locked = state_r[72];
wire [7:0] pl_evt = state_r[80:73];
wire [3:0] pl_mc_n = pl_any ? ((pl_mc == 4'hF) ? 4'hF : pl_mc + 4'd1) : 4'd0;
wire [3:0] pl_xc_n = pl_any ? 4'd0 : ((pl_xc == 4'hF) ? 4'hF : pl_xc + 4'd1);
wire pl_lock_n = pl_any ? ((pl_mc_n >= c[3:0]) ? 1'b1 : pl_locked)
                        : ((pl_xc_n >= c[7:4]) ? 1'b0 : pl_locked);
wire pl_lock_evt = pl_lock_n & ~pl_locked;
wire pl_loss_evt = ~pl_lock_n & pl_locked;
wire [7:0] pl_evt_n = (pl_evt == 8'hFF) ? 8'hFF : (pl_evt + {7'd0, pl_lock_evt});
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[30:12] != 19'd0 || c[3:0] == 4'd0 || c[7:4] == 4'd0) f = 1'b1;
else begin
    r = pl_m[31:0];
    x[0] = pl_m[32];
    x[1] = pl_any;
    x[2] = pl_lock_n;
    x[3] = pl_lock_evt;
    x[4] = pl_loss_evt;
    x[5] = pl_near;
    x[6] = pl_load;
    x[10:7] = pl_mc_n;
    x[14:11] = pl_xc_n;
    x[20:15] = pl_newest;
    x[25:21] = pl_cnt;
    x[31:26] = pl_dist;
    if(pl_loss_evt || pl_near) f = 1'b1;
    state_n = {175'd0, pl_evt_n, pl_lock_n, pl_xc_n, pl_mc_n, pl_pat, a};
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
