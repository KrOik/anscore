// Authored kernel. See ip/bch31_syndrome/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_bch31_syndrome (
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
reg [19:0] bch_syn;
reg [5:0] bch_pop, bch_wgt;
reg [4:0] bch_pos;
reg bch_any, bch_changed, bch_same;
reg [31:0] bch_cnt;
wire [30:0] bch_word = a[30:0];
wire bch_bad = (a[31] != 1'b0) || (c[29:0] != 29'd0);
wire [255:0] bch_base = c[31] ? 256'd0 : state_r;
wire [19:0] bch_acc = bch_base[19:0];
wire [30:0] bch_prevword = bch_base[62:32];
wire [31:0] bch_prevcnt = bch_base[95:64];
// 20 check rows of GF(32)/x^5+x^2+1, one 31-bit mask per syndrome bit, at a
// 32-bit stride; row index i = 5*(conjugacy class) + bit, matching the
// single-error column packing below.
wire [639:0] bch_rowall = {32'h715A193E, 32'h4FB8AD0C, 32'h4327DC56, 32'h64FB8AD0, 32'h34327DC5, 32'h70D48BEC, 32'h3522FB38, 32'h48BECE1A, 32'h5F670D48, 32'h59C3522F, 32'h77C985A8, 32'h2616A3BE, 32'h5A8EF930, 32'h4C2D477C, 32'h351DF261, 32'h5763E690, 32'h2BB1F348, 32'h15D8F9A4, 32'h5D8F9A42, 32'h2EC7CD21};
// the 20-bit syndrome of a single error at codeword position j, 31 of them,
// also at a 32-bit stride: the locator is 31 parallel comparators.
wire [991:0] bch_colall = {32'h000F5ED2, 32'h0009E329, 32'h0008EEB6, 32'h00041CCB, 32'h0005AB77, 32'h00060B99, 32'h000E2E3E, 32'h0005568F, 32'h00094E15, 32'h0007B858, 32'h000DD12C, 32'h000D12E6, 32'h000259E3, 32'h000BBD93, 32'h00030E7B, 32'h000773BF, 32'h0002B4FD, 32'h0004A1BC, 32'h000AA4AE, 32'h000FF887, 32'h00069A51, 32'h0001757A, 32'h000CEBCD, 32'h0001C314, 32'h0003C86A, 32'h000867E5, 32'h000B31D0, 32'h000C7F48, 32'h000EC544, 32'h000A1502, 32'h00008421};
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    bch_syn=20'd0; bch_pop=6'd0; bch_wgt=6'd0; bch_pos=5'd31; bch_any=1'b0;
       bch_changed=1'b0; bch_same=1'b0; bch_cnt=32'd0;
       if(bch_bad) f = 1'b1;
       else begin
           for(i=0; i<20; i=i+1)
               bch_syn[i] = ^(bch_word & bch_rowall[(i << 5) +: 31]);
           if(c[30]) bch_syn = bch_syn ^ bch_acc;
           for(i=0; i<20; i=i+1) if(bch_syn[i]) bch_pop = bch_pop + 6'd1;
           for(i=0; i<31; i=i+1) if(bch_word[i]) bch_wgt = bch_wgt + 6'd1;
           for(i=0; i<31; i=i+1) begin
               if(!bch_any && (bch_syn == bch_colall[(i << 5) +: 20])) begin
                   bch_any = 1'b1;
                   bch_pos = i;
               end
           end
           bch_changed = (bch_syn != bch_acc);
           bch_same = (bch_word == bch_prevword);
           bch_cnt = bch_prevcnt + 32'd1;
           r = {8'd0, c[30], (bch_syn != 20'd0) && !bch_any, bch_any,
                (bch_syn == 20'd0), bch_syn};
           x = {8'd0, bch_same, bch_changed, bch_wgt, bch_pop, c[31], c[30],
                ((bch_syn != 20'd0) && !bch_any), (bch_syn == 20'd0), bch_any,
                bch_pos};
           state_n = {112'd0, {12'd0, bch_acc}, 16'd0, bch_cnt,
                      {1'b0, bch_word}, {12'd0, bch_syn}};
           f = ((bch_syn != 20'd0) && !bch_any);
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
