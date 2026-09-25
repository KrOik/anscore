// Authored kernel. See ip/tab_gamma_lut16/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_tab_gamma_lut16 (
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
reg [11:0] gammamap [0:15];
initial $readmemh("tables/tab_gamma_lut16_gamma.mem", gammamap);
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(a[31:4] != 0 || c[31:5] != 0 || b[31:12] != 0 || (c & 32'h1f) > 16) f = 1'b1;
       else begin
           idx = a & 32'hf;
           lane = (idx == 15) ? 15 : (idx + 1);
           pa = gammamap[idx];
           pb = gammamap[lane];
           ph = pb - pa;
           pc = c & 32'h1f;
           pl = 0;
           if(pc == 16) pl = ph;
           else for(i=0; i<4; i=i+1) if(pc[3-i]) pl = pl + (ph >> (i + 1));
           temp = pa + pl + (b & 32'hfff);
           mask = 0;
           if(temp > 4095) begin
               temp = 4095;
               mask = 1 << 9;
           end
           r = temp;
           x = idx | (lane << 4) | ((pc == 16) ? (1 << 8) : 0) | mask | ((pc & 32'hf) << 10);
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
