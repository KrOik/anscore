// Authored kernel. See ip/qinq_walk/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_qinq_walk (
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
reg [15:0] n_etype;
function [1:0] nclass;
    input [15:0] t;
    begin
        nclass = 2'd0;
        if (t == 16'h8100) nclass = 2'd1;
        else if (t == 16'h88a8) nclass = 2'd2;
        else if (t == 16'h9100) nclass = 2'd3;
    end
endfunction
reg [15:0] n_tpid [0:2];
reg [15:0] n_tci [0:2];
reg [5:0] n_cmap;
reg [2:0] n_depth;
reg [1:0] n_cls, n_cin;
reg [11:0] n_vidin, n_vidout;
reg n_run, n_evid, n_edepth, n_nullin, n_nullout, n_deiin, n_deiout;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    n_tpid[0] = a[15:0]; n_tpid[1] = b[15:0]; n_tpid[2] = c[15:0];
       n_tci[0] = a[31:16]; n_tci[1] = b[31:16]; n_tci[2] = c[31:16];
       n_run = 1'b1;
       n_depth = 3'd0;
       n_etype = 16'h0;
       n_evid = 1'b0;
       n_vidin = 12'h0;
       n_deiin = 1'b0;
       n_cin = 2'd0;
       n_nullin = 1'b0;
       n_nullout = 1'b0;
       for (i=0; i<3; i=i+1) begin
           n_cls = nclass(n_tpid[i]);
           n_cmap[(2*i)+: 2] = n_cls;
           if (n_run) begin
               if (n_cls != 2'd0) begin
                   n_depth = n_depth + 3'd1;
                   n_vidin = n_tci[i][11:0];
                   n_deiin = n_tci[i][12];
                   n_cin = n_cls;
                   n_nullin = (n_tci[i][11:0] == 12'h000);
                   if (n_tci[i][11:0] == 12'hfff) n_evid = 1'b1;
                   if (i == 0) n_nullout = n_nullin;
               end
               else begin
                   n_etype = n_tpid[i];
                   n_run = 1'b0;
               end
           end
       end
       n_edepth = (n_depth == 3'd3);
       n_vidout = (n_depth == 3'd0) ? 12'h000 : n_tci[0][11:0];
       n_deiout = (n_depth == 3'd0) ? 1'b0 : n_tci[0][12];
       r[11:0] = n_vidout;
       r[23:12] = n_vidin;
       r[26:24] = n_depth;
       r[27] = (n_depth == 3'd0);
       r[28] = (n_depth >= 3'd2);
       r[29] = (n_cmap[1:0] == 2'd2);
       r[30] = (n_cin == 2'd1) && (n_depth != 3'd0);
       r[31] = (n_depth == 3'd1) && (n_cmap[1:0] == 2'd1);
       x[5:0] = n_cmap;
       x[6] = n_edepth;
       x[7] = n_evid;
       x[8] = n_nullout;
       x[9] = n_nullin;
       x[10] = n_deiout;
       x[11] = n_deiin;
       x[15:12] = 4'd0;
       x[31:16] = n_etype;
       f = n_edepth | n_evid;
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
