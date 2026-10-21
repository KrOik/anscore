// Authored kernel. See ip/md5_round/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_md5_round (
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
    if(c[30] && !c[31]) begin
    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
end else if(c[31] && c[30]) begin
    if(c[29:3] != 0 || c[2:0] > 3'd3) begin
        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
    end else begin
        case(c[2:0])
            3'd0: state_n = {state_r[255:32], a};
            3'd1: state_n = {state_r[255:64], a, state_r[31:0]};
            3'd2: state_n = {state_r[255:96], a, state_r[63:0]};
            3'd3: state_n = {state_r[255:128], a, state_r[95:0]};
            3'd4: state_n = state_r;
            3'd5: state_n = state_r;
            3'd6: state_n = state_r;
            3'd7: state_n = state_r;
        endcase
        r = a; x = 32'hC000_0000 | c[2:0];
    end
end else if(c[29:15] != 0 || c[7:0] != 0 || c[12:8] == 0) begin
    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
end else begin
    pa = (c[31] ? 32'h67452301 : state_r[31:0]);
    pb = (c[31] ? 32'hefcdab89 : state_r[63:32]);
    pc = (c[31] ? 32'h98badcfe : state_r[95:64]);
    ph = (c[31] ? 32'h10325476 : state_r[127:96]);
    case(c[14:13])
        2'd0: pl = (pb & pc) ^ (~pb & ph);
        2'd1: pl = (pb & ph) ^ (pc & ~ph);
        2'd2: pl = pb ^ pc ^ ph;
        default: pl = pc ^ (pb | ~ph);
    endcase
    mask = pl + pa + a + b;
    sh = c[12:8];
    wide[31:0] = (mask << sh) | (mask >> (32 - sh));
    r = pb + wide[31:0];
    x = mask;
    state_n = {128'd0, pc, pb, r, ph};
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
