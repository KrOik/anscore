// Authored kernel. See ip/ctl_watchdog_window32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ctl_watchdog_window32 (
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
    temp = a[15:0];
idx = a[19:16];
sa = {28'd0, state_r[115:112]};
sb = {28'd0, state_r[119:116]};
ph = 0;
pl = 0;
if (c[31] && (c[15:0] > b[15:0])) begin
    f = 1'b1;
    x[6] = 1'b1;
end
else if (c[31]) begin
    state_n[95:80] = c[15:0];
    state_n[111:96] = b[15:0];
    state_n[3:0] = 4'hf;
    state_n[7:4] = 4'h0;
    state_n[11:8] = 4'h0;
    state_n[15:12] = 4'h0;
    sa = 32'd0;
    sb = 32'd0;
    x[5] = 1'b1;
    for (lane = 0; lane < 4; lane = lane + 1)
        state_n[16 + 16*lane +: 16] = temp[15:0];
end
else if (a[20] && (idx > 4'd3)) begin
    f = 1'b1;
    x[6] = 1'b1;
end
else begin
    mask = 32'd0;
    if (a[20]) begin
        pa = (temp - state_r[16 + 16*idx +: 16]) & 16'hffff;
        if (!state_r[idx]) begin
            state_n[12+idx] = 1'b1;
            ph = ph | (32'd1 << idx);
            pl = pl + 32'd1;
            f = 1'b1;
        end
        else if (pa < state_r[95:80]) begin
            state_n[4+idx] = 1'b1;
            state_n[idx] = 1'b0;
            ph = ph | (32'd1 << idx);
            pl = pl + 32'd1;
            f = 1'b1;
        end
        else if (pa > state_r[111:96]) begin
            state_n[8+idx] = 1'b1;
            state_n[idx] = 1'b0;
            ph = ph | (32'd1 << idx);
            pl = pl + 32'd1;
            f = 1'b1;
        end
        else begin
            mask = 32'd1;
            x[4] = 1'b1;
        end
        state_n[16 + 16*idx +: 16] = temp[15:0];
    end
    for (lane = 0; lane < 4; lane = lane + 1) begin
        if (state_n[lane] &&
            (((temp - state_n[16 + 16*lane +: 16]) & 16'hffff)
             > state_n[111:96])) begin
            state_n[8+lane] = 1'b1;
            state_n[lane] = 1'b0;
            ph = ph | (32'd1 << lane);
            pl = pl + 32'd1;
            f = 1'b1;
        end
    end
    if (mask) sa = 32'd0;
    else begin
        sa = sa + 32'd1;
        if (sa > 32'd15) sa = 32'd15;
    end
    sb = sb + {28'd0, pl[3:0]};
    if (sb > 32'd15) begin
        sb = 32'd15;
        x[29] = 1'b1;
    end
    x[3:0] = ph;
end
state_n[115:112] = sa[3:0];
state_n[119:116] = sb[3:0];
r[3:0] = state_n[3:0];
r[7:4] = state_n[7:4];
r[11:8] = state_n[11:8];
r[15:12] = state_n[15:12];
r[31:16] = temp;
x[7] = (state_n[3:0] != 0);
x[11:8] = sa[3:0];
x[15:12] = sb[3:0];
x[27:24] = idx;
x[28] = a[20];
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
