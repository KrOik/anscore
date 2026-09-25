// Authored kernel. See ip/tdm8_demux/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_tdm8_demux (
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
reg [7:0] bm;
reg signed [31:0] mix;
reg lk, seq, orr, bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    bad = (c[30:3] != 0);
orr = (a[15:12] != {4{a[11]}});
seq = (c[31] == 1'b0) && (c[2:0] != state_r[138:136]);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    bm = (c[31] ? 8'd0 : state_r[135:128]) | (8'd1 << c[2:0]);
    lk = (bm == 8'hff);
    case (c[2:0])
        3'd0: state_n[15:0] = a[15:0];
        3'd1: state_n[31:16] = a[15:0];
        3'd2: state_n[47:32] = a[15:0];
        3'd3: state_n[63:48] = a[15:0];
        3'd4: state_n[79:64] = a[15:0];
        3'd5: state_n[95:80] = a[15:0];
        3'd6: state_n[111:96] = a[15:0];
        default: state_n[127:112] = a[15:0];
    endcase
    state_n[135:128] = bm;
    state_n[138:136] = c[2:0] + 3'd1;
    mix = $signed(state_n[15:0]) + $signed(state_n[31:16])
        + $signed(state_n[47:32]) + $signed(state_n[63:48])
        + $signed(state_n[79:64]) + $signed(state_n[95:80])
        + $signed(state_n[111:96]) + $signed(state_n[127:112]);
    r = {{16{a[15]}}, a[15:0]};
    x = {1'b0, c[31], lk, seq, orr, c[2:0], bm, mix[15:0]};
    f = orr || seq;
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
