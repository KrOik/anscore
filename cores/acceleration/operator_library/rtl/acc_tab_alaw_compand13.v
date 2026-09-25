// Authored kernel. See ip/tab_alaw_compand13/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_tab_alaw_compand13 (
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
reg [15:0] asegmap [0:7];
initial $readmemh("tables/tab_alaw_compand13_aseg.mem", asegmap);
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[31]) begin
           ext = a[12] ? (a | 32'hffffe000) : (a & 32'h1fff);
           mask = a ^ ext;
           if(mask != 0) f = 1'b1;
           else begin
               pb = a[12];
               ph = pb ? (0 - ext) : ext;
               j = 0;
               for(i=0; i<13; i=i+1) if(ph[i]) j = i;
               idx = (j <= 4) ? 0 : (j - 4);
               if(idx > 7) idx = 7;
               temp = asegmap[idx];
               pl = (ph >> (temp >> 12)) & 32'hf;
               if(ph > 4095) pl = 15;
               pa = (idx << 4) | pl;
               r = pa ^ (pb ? 32'h55 : 32'hd5);
               x = pa | (pb ? 32'h0 : 32'h100);
           end
       end
       else begin
           mask = a & 32'hffffff00;
           if(mask != 0) f = 1'b1;
           else begin
               pa = (a & 32'hff) ^ 32'h55;
               idx = (pa >> 4) & 32'h7;
               pl = pa & 32'hf;
               pb = pa[7];
               temp = asegmap[idx];
               ph = (pl << (temp >> 12)) + (temp & 32'hfff);
               r = pb ? ph : (0 - ph);
               x = (pb << 8) | (idx << 4) | pl;
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
                result<=r; aux<=x; fault<=f;
            end
        end
    end
end
endmodule
