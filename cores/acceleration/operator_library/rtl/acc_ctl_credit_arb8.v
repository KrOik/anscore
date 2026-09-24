// Authored kernel. See ip/ctl_credit_arb8/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ctl_credit_arb8 (
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
    pb = 0;
pa = 0;
idx = 0;
pl = 0;
ph = 0;
if (c[31]) begin
    for (lane = 0; lane < 8; lane = lane + 1) begin
        pc = {29'd0, c[3*lane +: 3]};
        pb = pb | (pc << (4*lane));
        state_n[4*lane +: 4] = pc[3:0];
        state_n[36 + 3*lane +: 3] = 3'd0;
    end
    state_n[34:32] = c[26:24];
    x[2:0] = c[26:24];
    x[5:3] = 3'd7;
    x[7] = 1'b1;
end
else begin
    for (lane = 0; lane < 8; lane = lane + 1) begin
        pc = {28'd0, state_r[4*lane +: 4]};
        if (a[8+lane]) pc = pc + 32'd1;
        if (pc > 32'd15) begin
            pc = 32'd15;
            x[26] = 1'b1;
        end
        if (a[16+lane]) begin
            if (pc == 0) x[25] = 1'b1;
            else pc = pc - 32'd1;
        end
        pb = pb | (pc << (4*lane));
        state_n[4*lane +: 4] = pc[3:0];
        if (a[lane] && b[lane]) begin
            if (pc == 0) f = 1'b1;
            else pa = pa | (32'd1 << lane);
        end
    end
    pc = {29'd0, state_r[34:32]};
    x[2:0] = pc[2:0];
    for (i = 0; i < 8; i = i + 1) begin
        lane = (pc + i) & 32'h7;
        if ((!idx) && pa[lane]) begin
            idx = 1;
            pl = lane;
            ph = 32'd1 << lane;
        end
    end
    if (idx) begin
        r[7:0] = ph;
        x[6] = 1'b1;
        x[5:3] = pl[2:0];
        pc = (pl + 1) & 32'h7;
        x[2:0] = pc[2:0];
        state_n[34:32] = pc[2:0];
        temp = pb[4*pl +: 4] - 32'd1;
        pb = (pb & ~(32'hf << (4*pl))) | (temp << (4*pl));
        state_n[4*pl +: 4] = temp[3:0];
    end
    else x[5:3] = 3'd7;
    x[15:8] = pa & ~ph;
    for (lane = 0; lane < 8; lane = lane + 1) begin
        if (idx && (pl == lane)) temp = 0;
        else if (pa[lane]) begin
            temp = {29'd0, state_r[36 + 3*lane +: 3]} + 32'd1;
            if (temp > 32'd7) begin
                temp = 32'd7;
                x[27] = 1'b1;
            end
        end
        else if ((!a[lane]) || (!b[lane])) temp = 0;
        else temp = {29'd0, state_r[36 + 3*lane +: 3]};
        state_n[36 + 3*lane +: 3] = temp[2:0];
        if ((temp != 0) && (b[15:8] != 0) && (temp >= {24'd0, b[15:8]}))
            x[16+lane] = 1'b1;
    end
end
temp = 0;
mask = 0;
for (lane = 0; lane < 8; lane = lane + 1) begin
    pc = pb[4*lane +: 4];
    temp = temp + pc;
    if (pc != 0) mask = mask | (32'd1 << lane);
end
r[15:8] = mask;
r[23:16] = temp[7:0];
temp = 0;
for (lane = 0; lane < 8; lane = lane + 1)
    if (a[lane] && b[lane]) temp = temp + 32'd1;
r[31:24] = temp[7:0];
x[24] = f;
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
