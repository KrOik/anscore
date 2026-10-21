// Authored kernel. See ip/ghash_mul32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ghash_mul32 (
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
reg [127:0] zz, vv, pw;
reg fb;
localparam [127:0] RH = 128'he1000000000000000000000000000000;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    zz = state_r[127:0];
vv = state_r[255:128];
pw = a;
fb = 1'b0;
if(c[30:4] != 0 || c[2]) begin
    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
end else if(c[3]) begin
    if(c[31]) begin
        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
    end else begin
        temp = 32'd0;
        for(lane = 0; lane < 32; lane = lane + 1) begin
            if(pw[31]) begin
                zz = zz ^ vv;
                temp = temp + 32'd1;
            end
            fb = vv[0];
            vv = vv >> 1;
            if(fb) vv = vv ^ RH;
            pw = pw << 1;
        end
        state_n = {vv, zz};
        r = zz[31:0];
        x = {20'd0, c[1:0], 8'd0} | temp;
        if(c[1:0] == 2'd3) x = x | 32'h8000_0000;
    end
end else begin
    if(c[31] && c[1:0] != 0) begin
        f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
    end else begin
        if(c[31]) zz = 128'd0;
        case(c[1:0])
            2'd0: vv = {b, vv[95:0]};
            2'd1: vv = {vv[127:96], b, vv[63:0]};
            2'd2: vv = {vv[127:64], b, vv[31:0]};
            default: vv = {vv[127:32], b};
        endcase
        state_n = {vv, zz};
        r = b;
        x = 32'h4000_0000 | {20'd0, c[1:0], 8'd0};
        if(c[31]) x = x | 32'h8000_0000;
    end
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
