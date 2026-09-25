// Authored kernel. See ip/karplus_strong/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_karplus_strong (
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
reg [11:0] dm, outv;
reg [4:0] ll, ee, nx;
reg [3:0] p, pn;
reg signed [63:0] xv, d0v, ssum, dsh, fb;
reg ovr, bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    bad = (c[30:3] != 0);
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    p = c[31] ? 4'd0 : state_r[207:204];
    case (c[1:0])
        2'd0: ll = 5'd4;
        2'd1: ll = 5'd8;
        2'd2: ll = 5'd12;
        default: ll = 5'd16;
    endcase
    ee = c[2] ? 5'd4 : 5'd7;
    nx = {1'b0, p} + 5'd1;
    pn = (nx >= ll) ? 4'd0 : nx[3:0];
    xv = $signed({{20{a[11]}}, a[11:0]});
    case (p)
        4'd0: dm = state_r[11:0];
        4'd1: dm = state_r[23:12];
        4'd2: dm = state_r[35:24];
        4'd3: dm = state_r[47:36];
        4'd4: dm = state_r[59:48];
        4'd5: dm = state_r[71:60];
        4'd6: dm = state_r[83:72];
        4'd7: dm = state_r[95:84];
        4'd8: dm = state_r[107:96];
        4'd9: dm = state_r[119:108];
        4'd10: dm = state_r[131:120];
        4'd11: dm = state_r[143:132];
        4'd12: dm = state_r[155:144];
        4'd13: dm = state_r[167:156];
        4'd14: dm = state_r[179:168];
        4'd15: dm = state_r[191:180];
        default: dm = 12'd0;
    endcase
    d0v = $signed(state_r[203:192]);
    ssum = c[31] ? 64'sd0 : (d0v + $signed(dm));
    dsh = ssum >>> ee;
    fb = ((ssum - dsh) >>> 1) + xv;
    ovr = (fb > 64'sd2047) || (fb < -64'sd2048);
    outv = (fb > 64'sd2047) ? 12'h7ff :
           (fb < -64'sd2048) ? 12'h800 : fb[11:0];
    r = {{20{outv[11]}}, outv};
    x = {10'd0, fb[13:0], c[31], ovr, c[1:0], pn};
    f = ovr;
    state_n = c[31] ? 256'd0 : state_r;
    case (p)
        4'd0: state_n[11:0] = outv;
        4'd1: state_n[23:12] = outv;
        4'd2: state_n[35:24] = outv;
        4'd3: state_n[47:36] = outv;
        4'd4: state_n[59:48] = outv;
        4'd5: state_n[71:60] = outv;
        4'd6: state_n[83:72] = outv;
        4'd7: state_n[95:84] = outv;
        4'd8: state_n[107:96] = outv;
        4'd9: state_n[119:108] = outv;
        4'd10: state_n[131:120] = outv;
        4'd11: state_n[143:132] = outv;
        4'd12: state_n[155:144] = outv;
        4'd13: state_n[167:156] = outv;
        4'd14: state_n[179:168] = outv;
        4'd15: state_n[191:180] = outv;
    endcase
    state_n[203:192] = outv;
    state_n[207:204] = pn;
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
