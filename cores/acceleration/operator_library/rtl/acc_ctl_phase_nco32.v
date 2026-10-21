// Authored kernel. See ip/ctl_phase_nco32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ctl_phase_nco32 (
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
    if ((b[31:17] != 0) || (c[30:0] != 0)) begin
    f = 1'b1;
    r = state_r[31:0];
    x[1:0] = state_r[31:30];
    x[15:8] = state_r[39:32];
end
else if (c[31]) begin
    r = a;
    x[1:0] = a[31:30];
    x[16] = 1'b1;
    state_n[31:0] = a;
    state_n[39:32] = 8'd0;
end
else begin
    swide = $signed({1'b0, state_r[31:0]});
    if (b[16]) swide = swide - $signed({1'b0, a});
    else swide = swide + $signed({1'b0, a});
    swide = swide + {{48{b[15]}}, b[15:0]};
    r = swide[31:0];
    x[1:0] = swide[31:30];
    state_n[31:0] = swide[31:0];
    swide2 = swide >>> 32;
    if (swide2 < 0) begin swide2 = -swide2; x[3] = 1'b1; end
    else if (swide2 != 0) x[2] = 1'b1;
    pa = {24'd0, state_r[39:32]} + {28'd0, swide2[3:0]};
    if (pa[8]) begin temp = 32'd255; x[4] = 1'b1; end
    else temp = pa;
    state_n[39:32] = temp[7:0];
    x[15:8] = temp[7:0];
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
