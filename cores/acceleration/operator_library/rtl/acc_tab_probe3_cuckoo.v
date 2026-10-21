// Authored kernel. See ip/tab_probe3_cuckoo/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_tab_probe3_cuckoo (
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
    pa = a & 32'hffff;
       pb = pa & 32'h7;
       pc = ((pa >> 3) ^ (pa >> 6) ^ (pa >> 9) ^ (pa >> 12)) & 32'h7;
       ph = ((pa >> 1) ^ (pa >> 4) ^ (pa >> 7) ^ (pa >> 10) ^ (pa >> 13) ^ (pa >> 15)) & 32'h7;
       if(a[31:16] != 0) f = 1'b1;
       else if(c[31] && c[30]) begin
           state_n = 0;
       end
       else begin
           j = 0;
           lane = 0;
           idx = 0;
           sh = 0;
           mask = 0;
           for(i=0; i<3; i=i+1) begin
               temp = (i == 0) ? pb : ((i == 1) ? pc : ph);
               temp = state_r[(temp << 5) +: 32];
               if(!temp[31]) begin
                   lane = lane + 1;
                   if(sh == 0) sh = i + 1;
               end
               else if(temp[15:0] != pa) j = j + 1;
               else if(idx == 0) idx = i + 1;
           end
           for(i=0; i<8; i=i+1) if(state_r[(i << 5) + 31]) mask = mask + 1;
           if(c[31] && idx == 0 && sh == 0) f = 1'b1;
           else begin
               x = (ph << 6) | (pc << 3) | pb | (lane << 9) | (j << 11) | (mask << 17);
               if(c[31]) begin
                   if(idx == 0) idx = sh;
                   lane = (idx == 1) ? pb : ((idx == 2) ? pc : ph);
                   state_n[(lane << 5) +: 32] = 32'h80000000 | ((b & 32'hff) << 16) | pa;
                   r = pa | ((b & 32'hff) << 16) | (idx << 24);
               end
               else begin
                   temp = 0;
                   if(idx != 0) begin
                       lane = (idx == 1) ? pb : ((idx == 2) ? pc : ph);
                       temp = state_r[(lane << 5) +: 32];
                   end
                   r = pa | (temp & 32'hff0000) | (idx << 24);
               end
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
