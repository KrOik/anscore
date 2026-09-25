// Authored kernel. See ip/xtea_block/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_xtea_block (
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
    if(c[29:2] != 0) begin
    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
end else if(c[31]) begin
    if(c[1:0] != 0) begin
        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
    end else begin
        state_n = {{31'd0, c[30]}, state_r[223:96],
                   c[30] ? 32'hC6EF_3720 : 32'd0, b, a};
        r = a; x = 32'h8000_0000 | {31'd0, c[30]};
    end
end else if(c[30]) begin
    case(c[1:0])
        2'd0: state_n = {state_r[255:128], a, state_r[95:0]};
        2'd1: state_n = {state_r[255:160], a, state_r[127:0]};
        2'd2: state_n = {state_r[255:192], a, state_r[159:0]};
        default: state_n = {state_r[255:224], a, state_r[191:0]};
    endcase
    r = a; x = 32'h4000_0000 | {30'd0, c[1:0]};
end else if(c[1:0] != 0) begin
    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
end else begin
    pa = state_r[31:0];
    pb = state_r[63:32];
    pl = state_r[95:64];
    ph = |state_r[255:224];
    mask = ph ? (pl - 32'h9e37_79b9) : (pl + 32'h9e37_79b9);
    idx = ph ? pl[12:11] : pl[1:0];
        case(idx)
            2'd0: pc = state_r[127:96];
            2'd1: pc = state_r[159:128];
            2'd2: pc = state_r[191:160];
            default: pc = state_r[223:192];
        endcase
    if(ph) begin
        temp = (((pa << 4) ^ (pa >> 5)) + pa) ^ (pl + pc);
        pb = pb - temp;
    end else begin
        temp = (((pb << 4) ^ (pb >> 5)) + pb) ^ (pl + pc);
        pa = pa + temp;
    end
    idx = ph ? mask[1:0] : mask[12:11];
        case(idx)
            2'd0: pc = state_r[127:96];
            2'd1: pc = state_r[159:128];
            2'd2: pc = state_r[191:160];
            default: pc = state_r[223:192];
        endcase
    if(ph) begin
        temp = (((pb << 4) ^ (pb >> 5)) + pb) ^ (mask + pc);
        pa = pa - temp;
    end else begin
        temp = (((pa << 4) ^ (pa >> 5)) + pa) ^ (mask + pc);
        pb = pb + temp;
    end
    r = pa; x = pb;
    state_n = {state_r[255:224], state_r[223:96], mask, pb, pa};
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
