// Authored kernel. See ip/ipv4_hdr_csum/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ipv4_hdr_csum (
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
reg [17:0] n_acc, n_store;
reg [31:0] n_sum, n_s1, n_s2;
reg [15:0] n_fin;
reg [7:0] n_beats;
reg n_mis, n_stick, n_ok;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_store = 18'h0;
       if (c[28:16] != 13'd0) begin
           f = 1'b1;
       end
       else begin
           n_acc = c[31] ? 18'd0 : state_r[17:0];
           n_beats = c[31] ? 8'h00 : state_r[25:18];
           n_stick = c[31] ? 1'b0 : state_r[26];
           n_sum = n_acc + {16'd0, a[15:0]} + {16'd0, a[31:16]}
                 + {16'd0, b[15:0]} + {16'd0, b[31:16]};
           n_mis = (n_sum > 32'h3ffff);
           if (n_mis) begin
               n_sum = (n_sum & 32'hffff) + (n_sum >> 16);
               n_sum = (n_sum & 32'hffff) + (n_sum >> 16);
           end
           n_store = n_sum[17:0];
           n_fin = 16'h0;
           n_ok = 1'b0;
           if (c[30]) begin
               n_s1 = {2'd0, n_store[15:0]} + {16'd0, n_store[17:16]};
               n_s2 = {16'd0, n_s1[15:0]} + {30'd0, n_s1[16]};
               n_fin = n_s2[15:0];
               n_ok = (n_fin == 16'hffff);
               n_store = {2'd0, n_fin};
           end
           if (!c[30]) r = {14'd0, n_store};
           else if (c[29]) r = {16'd0, n_fin};
           else r = {16'd0, (n_fin ^ 16'hffff)};
           if (c[30] && c[29] && !n_ok) f = 1'b1;
           if (n_mis) f = 1'b1;
           if (n_beats != 8'hff) n_beats = n_beats + 8'd1;
           if (n_mis) n_stick = 1'b1;
           x = {14'd0, n_store};
           x[18] = n_mis;
           x[19] = c[30];
           x[20] = c[29];
           x[21] = n_ok;
           x[22] = n_stick;
           x[31:24] = n_beats;
           state_n[17:0] = n_store;
           state_n[25:18] = n_beats;
           state_n[26] = n_stick;
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
