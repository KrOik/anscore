// Authored kernel. See ip/lfsr_galois_keystream/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_lfsr_galois_keystream (
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
    mask = state_r[31:0];
pb = 32'd0;
if(c[29:0] != 30'd0) begin
    f = 1'b1; r = 32'd0; x = 32'd0;
    state_n = state_r;
end else if(c[31]) begin
    state_n = {160'd0, 32'd0, 32'd0, a};
    r = a; x = 32'h8000_0000;
    if(a == 32'd0) f = 1'b1;
end else begin
    for(lane = 0; lane < 8; lane = lane + 1) begin
        if(!c[30] || lane == 0) begin
            pc = mask[0];
            mask = mask >> 1;
            if(pc) mask = mask ^ 32'h8020_0003;
            if(pc) pb = pb | (32'd1 << lane);
        end
    end
    ph = state_r[63:32] ^ pb;
    pl = state_r[95:64] + 32'd1;
    state_n = {160'd0, pl, ph, mask};
    r = mask; x = pb | (pl << 8);
    if(mask == 32'd0) f = 1'b1;
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
