// Authored kernel. See ip/goertzel_dtmf/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_goertzel_dtmf (
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
reg signed [63:0] s1, s2, xin, acc, sv;
reg [25:0] sn1, sn2, e1, e2;
reg [31:0] hv;
reg oaa, oee, bad;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    bad = (c[30:3] != 0) || ((c[2:0] != state_r[54:52]) && (c[31] == 1'b0));
if (bad) begin
    r = 0; x = 0; f = 1;
    state_n = 0;
end else begin
    s1 = c[31] ? 64'sd0 : $signed(state_r[25:0]);
    s2 = c[31] ? 64'sd0 : $signed(state_r[51:26]);
    xin = $signed({{20{a[11]}}, a[11:0]});
    acc = (xin <<< 26);
    case (c[2:0])
        3'd0: acc = acc + (s1 <<< 15) - (s1 <<< 12) - (s1 <<< 10)
                    + (s1 <<< 8) + (s1 <<< 6) + (s1 <<< 4) - (s1 <<< 2);
        3'd1: acc = acc + (s1 <<< 15) - (s1 <<< 13) + (s1 <<< 11)
                    + (s1 <<< 8) + (s1 <<< 6) + (s1 <<< 4) - (s1 <<< 2);
        3'd2: acc = acc + (s1 <<< 15) - (s1 <<< 13) + (s1 <<< 10)
                    + (s1 <<< 7) - (s1 <<< 5) + (s1 <<< 2) + (s1 <<< 0);
        3'd3: acc = acc + (s1 <<< 15) - (s1 <<< 13) - (s1 <<< 9)
                    + (s1 <<< 7) + (s1 <<< 5) - (s1 <<< 2) - (s1 <<< 0);
        3'd4: acc = acc + (s1 <<< 14) + (s1 <<< 11) + (s1 <<< 9)
                    + (s1 <<< 7) + (s1 <<< 0);
        3'd5: acc = acc + (s1 <<< 14) - (s1 <<< 6) + (s1 <<< 2) + (s1 <<< 0);
        3'd6: acc = acc + (s1 <<< 14) - (s1 <<< 12) + (s1 <<< 10)
                    - (s1 <<< 8) + (s1 <<< 5) - (s1 <<< 2) + (s1 <<< 0);
        default: acc = acc + (s1 <<< 13) + (s1 <<< 10) + (s1 <<< 7)
                    - (s1 <<< 5) + (s1 <<< 2) - (s1 <<< 0);
    endcase
    acc = acc - (s2 <<< 14);
    sv = (acc + 64'sd8192) >>> 14;
    oaa = (sv > 64'sd33554431) || (sv < -64'sd33554431);
    sn1 = (sv > 64'sd33554431) ? 26'sd33554431 :
          (sv < -64'sd33554431) ? -26'sd33554431 : sv[25:0];
    sn2 = c[31] ? 26'd0 : state_r[25:0];
    e1 = sn1[25] ? ((~sn1) + 26'd1) : sn1;
    e2 = sn2[25] ? ((~sn2) + 26'd1) : sn2;
    hv = ((e1 + e2) + 32'd4096) >>> 13;
    oee = hv > 32'd2047;
    r = (oee ? 12'd2047 : hv[11:0]);
    x = {1'b0, c[2:0], e1[25:14], e2[25:14], oee, oaa, 1'b0, c[31]};
    f = oaa || oee;
    state_n = {1'b0, c[2:0], sn2, sn1};
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
