// Authored kernel. See ip/toeplitz_rss/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_toeplitz_rss (
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
reg [31:0] keymap [0:1];
initial $readmemh("tables/toeplitz_rss_key.mem", keymap);
reg [63:0] n_key;
reg [31:0] n_ain, n_out, n_drop, n_rev;
reg [5:0] n_cnt;
reg n_stray;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_key = {keymap[1], keymap[0]};
       n_ain = a;
       n_stray = 1'b0;
       for (i=0; i<4; i=i+1) begin
           if (!b[i]) begin
               if (n_ain[(8*i)+: 8] != 8'd0) n_stray = 1'b1;
               n_ain[(8*i)+: 8] = 8'd0;
           end
       end
       if (c[31]) begin
           for (i=0; i<32; i=i+1) n_rev[i] = n_ain[31-i];
           n_ain = n_rev;
       end
       n_out = 32'h0;
       n_drop = 32'h0;
       n_cnt = 6'd0;
       for (i=0; i<32; i=i+1) begin
           if (n_ain[i]) begin
               n_out = n_out ^ ((n_key >> i) & 32'hffffffff);
               n_drop = n_drop ^ (n_key >> (i + 32));
               n_cnt = n_cnt + 6'd1;
           end
       end
       if (b[31:4] != 28'd0) begin
           f = 1'b1;
       end
       else begin
           r = n_out;
           x[5:0] = n_cnt;
           x[6] = c[31];
           x[10:7] = b[3:0];
           x[11] = n_stray;
           x[15:12] = 4'd0;
           x[31:16] = (n_drop >> 16) ^ n_drop;
           if (n_stray) f = 1'b1;
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
