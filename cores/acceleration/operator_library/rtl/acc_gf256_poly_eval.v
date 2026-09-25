// Authored kernel. See ip/gf256_poly_eval/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_gf256_poly_eval (
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
// Image generated from the family model; read combinationally here.
reg [15:0] pemap [0:255];
initial $readmemh("tables/gf256_poly_eval_pm16.mem", pemap);

reg [7:0] pe_pv, pe_prod, pe_la;
reg [8:0] pe_sm;
reg [31:0] pe_stg;
reg [23:0] pe_cnt;
reg pe_zeroed, pe_sticky;
wire [7:0] pe_k = c[7:0];
wire pe_bad = (pe_k == 8'd255) || (c[30:8] != 23'd0);
wire [255:0] pe_base = c[31] ? 256'd0 : state_r;
wire [23:0] pe_prevcnt = pe_base[31:8];
wire [31:0] pe_prevpv = pe_base[127:96];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    pe_pv=8'd0; pe_prod=8'd0; pe_la=8'd0; pe_sm=9'd0; pe_stg=32'd0;
       pe_cnt=24'd0; pe_zeroed=1'b0; pe_sticky=1'b0;
       if(pe_bad) f = 1'b1;
       else begin
           pe_pv = pe_base[7:0];
           for(j=0; j<4; j=j+1) begin
               if(pe_pv == 8'd0) begin
                   pe_prod = 8'd0;
                   pe_zeroed = 1'b1;
               end
               else begin
                   pe_la = pemap[pe_pv & 8'hff] >> 8;
                   pe_sm = pe_la + pe_k;
                   if(pe_sm >= 255) pe_sm = pe_sm - 255;
                   pe_prod = pemap[pe_sm[7:0]] & 8'hff;
               end
               idx = (j + 8) << 3;
               pe_pv = pe_prod ^ data[idx +: 8];
               pe_stg[((3 - j) << 3) +: 8] = pe_pv;
           end
           pe_cnt = (pe_prevcnt == 24'hffffff) ? 24'hffffff
                    : (pe_prevcnt + 24'd4);
           r = pe_stg;
           x = {pe_cnt[11:0], (pe_prevcnt == 24'hffffff),
                (pe_prevpv == pe_stg[31:24]), pe_zeroed, c[31], pe_k,
                pe_base[7:0]};
           state_n = {126'd0, (pe_base[129] || (pe_prevcnt == 24'hffffff)),
                      1'b1, {24'd0, pe_base[7:0]}, pe_base[63:32], a,
                      pe_cnt, pe_stg[7:0]};
           f = (pe_prevcnt == 24'hffffff);
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
