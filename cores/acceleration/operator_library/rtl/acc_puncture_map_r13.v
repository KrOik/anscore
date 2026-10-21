// Authored kernel. See ip/puncture_map_r13/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_puncture_map_r13 (
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
reg [31:0] pat [0:3];
initial $readmemh("tables/puncture_map_r13_pat.mem", pat);

reg [31:0] pu_out, pu_mask, pu_total, pu_beats, pu_emit;
reg pu_illegal, pu_first, pu_same;
reg [3:0] pu_skip;
wire [1:0] pu_sel = c[1:0];
wire pu_bad = (c[30:4] != 27'd0);
wire [255:0] pu_base = c[31] ? 256'd0 : state_r;
wire [31:0] pu_prevout = pu_base[31:0];
wire [31:0] pu_prevmask = pu_base[63:32];
wire [15:0] pu_prevbeats = pu_base[79:64];
wire [15:0] pu_prevtotal = pu_base[95:80];
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    pu_out=32'd0; pu_mask=32'd0; pu_total=32'd0; pu_beats=32'd0; pu_emit=32'd0;
       pu_illegal=1'b0; pu_first=1'b0; pu_same=1'b0; pu_skip=4'd0;
       if(pu_bad) f = 1'b1;
       else begin
           pu_mask = pat[pu_sel];
           pu_illegal = (pu_mask == 32'd0);
           sh = 0;
           for(i=0; i<32; i=i+1) begin
               if(pu_mask[i]) begin
                   if(!a[i] && pu_skip != 4'd15) pu_skip = pu_skip + 4'd1;
                   if(!c[3]) begin
                       if(a[i]) pu_out = pu_out | (32'h1 << sh);
                   end
                   else if(a[sh]) pu_out = pu_out | (32'h1 << i);
                   sh = sh + 1;
               end
           end
           pu_total = {27'd0, sh};
           if(pu_prevbeats == 16'hffff) pu_beats = 32'hffff;
           else pu_beats = pu_prevbeats + 32'd1;
           if(pu_prevtotal > 32'hffff - pu_total) pu_emit = 32'hffff;
           else pu_emit = pu_prevtotal + pu_total;
           pu_first = (pu_prevbeats == 16'd0);
           pu_same = (pu_out == pu_prevout);
           r = pu_out;
           x = {pu_beats[7:0], pu_emit[7:0], pu_skip, (pu_prevmask == pu_mask),
                pu_same, pu_first, c[31], pu_illegal, c[3], pu_total[5:0]};
           state_n = {128'd0, a, pu_emit[15:0], pu_beats[15:0], pu_mask, pu_out};
           f = pu_illegal || (pu_prevbeats == 16'hffff);
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
