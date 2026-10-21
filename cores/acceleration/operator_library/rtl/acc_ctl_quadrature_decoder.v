// Authored kernel. See ip/ctl_quadrature_decoder/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ctl_quadrature_decoder (
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
    if (a[31:16] != 0) begin
    f = 1'b1;
    r = state_r[31:0];
    x[25:24] = state_r[33:32];
    x[31:28] = state_r[39:36];
end
else begin
    if (c[31]) swide = 64'sd0;
    else if (c[30]) swide = $signed(b);
    else swide = $signed({{32{state_r[31]}}, state_r[31:0]});
    mask = state_r[33:32];
    pc = 0;
    for (i = 0; i < 8; i = i + 1) begin
        idx = a[2*i +: 2];
        if (idx != mask) begin
            x[i+8] = 1'b1;
            pb = mask ^ (mask >> 1);
            ph = idx ^ (idx >> 1);
            temp = (pb + 1) & 3;
            if (ph == temp) swide = swide + 1;
            else begin
                temp = (pb + 2) & 3;
                if (ph == temp) begin
                    x[i+16] = 1'b1;
                    f = 1'b1;
                    pc = pc + 1;
                end
                else begin
                    swide = swide - 1;
                    x[i] = 1'b1;
                end
            end
        end
        mask = idx;
    end
    r = swide[31:0];
    state_n[31:0] = swide[31:0];
    state_n[33:32] = mask[1:0];
    x[25:24] = mask[1:0];
    temp = {28'd0, state_r[39:36]} + {28'd0, pc[3:0]};
    if (temp > 32'd15) begin
        temp = 32'd15;
        x[27] = 1'b1;
    end
    state_n[39:36] = temp[3:0];
    x[31:28] = temp[3:0];
    x[26] = c[31] | c[30];
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
