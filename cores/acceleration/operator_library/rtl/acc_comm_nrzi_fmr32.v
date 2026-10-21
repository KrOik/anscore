// Authored kernel. See ip/comm_nrzi_fmr32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_comm_nrzi_fmr32 (
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
function [5:0] pc32;                       // popcount of a 32-bit word
    input [31:0] v;
    reg [31:0] t;
    begin
        t = v - ((v >> 1) & 32'h55555555);
        t = (t & 32'h33333333) + ((t >> 2) & 32'h33333333);
        t = (t + (t >> 4)) & 32'h0F0F0F0F;
        t = t + (t >> 8);
        t = t + (t >> 16);
        pc32 = t[5:0];
    end
endfunction

function [5:0] tz32;                       // zeros below the lowest set bit, 32 if empty
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        t = v; n = 6'd0;
        if((t & 32'h0000FFFF) == 32'd0) begin n = n + 6'd16; t = t >> 16; end
        if((t & 32'h000000FF) == 32'd0) begin n = n + 6'd8;  t = t >> 8;  end
        if((t & 32'h0000000F) == 32'd0) begin n = n + 6'd4;  t = t >> 4;  end
        if((t & 32'h00000003) == 32'd0) begin n = n + 6'd2;  t = t >> 2;  end
        if((t & 32'h00000001) == 32'd0) begin n = n + 6'd1;  t = t >> 1;  end
        tz32 = (v == 32'd0) ? 6'd32 : n;
    end
endfunction

function [5:0] lz32;                       // zeros above the highest set bit, 32 if empty
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        t = v; n = 6'd0;
        if((t & 32'hFFFF0000) == 32'd0) begin n = n + 6'd16; t = t << 16; end
        if((t & 32'hFF000000) == 32'd0) begin n = n + 6'd8;  t = t << 8;  end
        if((t & 32'hF0000000) == 32'd0) begin n = n + 6'd4;  t = t << 4;  end
        if((t & 32'hC0000000) == 32'd0) begin n = n + 6'd2;  t = t << 2;  end
        if((t & 32'h80000000) == 32'd0) begin n = n + 6'd1;  t = t << 1;  end
        lz32 = (v == 32'd0) ? 6'd32 : n;
    end
endfunction

function [31:0] px32;                      // bit k = XOR of v[k:0], five XOR levels
    input [31:0] v;
    reg [31:0] t;
    begin
        t = v;
        t = t ^ (t << 1);
        t = t ^ (t << 2);
        t = t ^ (t << 4);
        t = t ^ (t << 8);
        t = t ^ (t << 16);
        px32 = t;
    end
endfunction

wire       nr_ref = c[31] ? 1'b0 : state_r[0];
wire [7:0] nr_run = c[31] ? 8'd0 : state_r[8:1];
wire [7:0] nr_tot = c[31] ? 8'd0 : state_r[31:24];
// Transition map: where the channel level changes, which is the data word.
wire [31:0] nr_map = c[30] ? a : (a ^ ((a << 1) | {31'd0, nr_ref}));
// Channel word: NRZI is the running XOR of the data, so encoding is a prefix XOR.
wire [31:0] nr_chan = c[30] ? (px32(a) ^ (nr_ref ? 32'hFFFFFFFF : 32'h00000000)) : a;
wire [31:0] nr_out  = c[30] ? nr_chan : nr_map;
wire        nr_lvl  = c[30] ? nr_chan[31] : a[31];
wire [5:0]  nr_dens = pc32(nr_map);
wire [8:0]  nr_raw_out = (nr_map == 32'd0)
    ? ({1'b0, nr_run} + 9'd32) : {3'd0, lz32(nr_map)};
wire [9:0]  nr_raw_span = {2'b0, nr_run} + {4'b0, tz32(nr_map)};
wire [7:0]  nr_run_out  = (nr_raw_out  > 10'd255) ? 8'hFF : nr_raw_out[7:0];
wire [7:0]  nr_run_span = (nr_raw_span > 10'd255) ? 8'hFF : nr_raw_span[7:0];
wire [9:0]  nr_tot_raw = {2'b0, nr_tot} + {4'b0, nr_dens};
wire [7:0]  nr_tot_out = (nr_tot_raw > 10'd255) ? 8'hFF : nr_tot_raw[7:0];
wire nr_alarm =
      ((b[5:0]  != 6'd0)  && ({1'b0, nr_dens} > {1'b0, b[5:0]}))
   || ((b[11:6] != 6'd0)  && ({1'b0, nr_dens} < {1'b0, b[11:6]}))
   || ((b[19:12] != 8'd0) && (nr_raw_out  > {1'b0, b[19:12]}))
   || ((b[19:12] != 8'd0) && (nr_raw_span > {2'b0, b[19:12]}));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[29:1] != 29'd0 || b[31:20] != 12'd0) f = 1'b1;
else begin
    r = nr_out;
    x[5:0] = nr_dens;
    x[13:6] = nr_run_out;
    x[21:14] = nr_run_span;
    x[22] = (nr_map == 32'd0);
    x[23] = nr_alarm;
    x[31:24] = nr_tot_out;
    if(nr_alarm) f = 1'b1;
    state_n = {224'd0, nr_tot_out, 15'd0, nr_run_out, nr_lvl};
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
