// Authored kernel. See ip/svpwm_sector/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_svpwm_sector (
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
reg signed [12:0] Uv, Vv, Wv, Xv, Yv, Zv, t1v, t2v, limv;
reg signed [13:0] sumv;
reg [2:0] key, svp_sec, svp_va, svp_vb;
reg ovr, dgen;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    Uv = {{2{a[10]}}, a[10:0]};
Vv = {{2{a[21]}}, a[21:11]};
Wv = {{2{b[10]}}, b[10:0]};
Xv = Vv - Wv;
Yv = Wv - Uv;
Zv = Uv - Vv;
key = {Zv > 13'sd0, Yv > 13'sd0, Xv > 13'sd0};
case(key)
                3'd1: svp_sec = 3'd2;
                3'd2: svp_sec = 3'd4;
                3'd3: svp_sec = 3'd3;
                3'd4: svp_sec = 3'd6;
                3'd5: svp_sec = 3'd1;
                3'd6: svp_sec = 3'd5;
                default: svp_sec = 3'd0;
    endcase
    case(key)
                3'd1: t1v = -Yv;
                3'd2: t1v = -Zv;
                3'd3: t1v = Xv;
                3'd4: t1v = -Xv;
                3'd5: t1v = Zv;
                3'd6: t1v = Yv;
                default: t1v = 13'sd0;
    endcase
    case(key)
                3'd1: t2v = -Zv;
                3'd2: t2v = -Xv;
                3'd3: t2v = Yv;
                3'd4: t2v = -Yv;
                3'd5: t2v = Xv;
                3'd6: t2v = Zv;
                default: t2v = 13'sd0;
    endcase
    case(svp_sec)
                3'd1: svp_va = 3'b100;
                3'd2: svp_va = 3'b110;
                3'd3: svp_va = 3'b010;
                3'd4: svp_va = 3'b011;
                3'd5: svp_va = 3'b001;
                3'd6: svp_va = 3'b101;
                default: svp_va = 3'b000;
    endcase
    case(svp_sec)
                3'd1: svp_vb = 3'b110;
                3'd2: svp_vb = 3'b010;
                3'd3: svp_vb = 3'b011;
                3'd4: svp_vb = 3'b001;
                3'd5: svp_vb = 3'b101;
                3'd6: svp_vb = 3'b100;
                default: svp_vb = 3'b000;
    endcase
    limv = $signed({1'b0, c[11:0]});
    sumv = t1v + t2v;
    ovr = c[31] && (sumv > limv);
    dgen = (key == 3'd0);
    if(a[31:22]!=0 || b[31:11]!=0 || c[30:12]!=0) f=1'b1;
    else begin
        r = {ovr, dgen, svp_vb, svp_va, t2v[11:0], t1v[11:0]};
        x = {13'd0, c[31], key, svp_sec, c[11:0]};
        f = ovr || dgen;
    end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f;
            end
        end
    end
end
endmodule
