// Authored kernel. See ip/manchester_io/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_manchester_io (
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
function [5:0] pc32;                        // popcount, pairwise half adds
    input [31:0] v;
    reg [31:0] t;
    begin
        t = (v & 32'h55555555) + ((v >> 1) & 32'h55555555);
        t = (t & 32'h33333333) + ((t >> 2) & 32'h33333333);
        t = (t & 32'h0F0F0F0F) + ((t >> 4) & 32'h0F0F0F0F);
        // The byte fold has to be two sequential half-adds.  Written as one
        // parallel sum t + (t>>8) + (t>>16) the bit 31:24 group lands in byte 1
        // instead of byte 0, so every popcount silently lost its top byte.
        t = t + (t >> 8);
        t = t + (t >> 16);
        pc32 = t[5:0];
    end
endfunction

function [5:0] lo32;                        // index of the lowest set bit, 32 if 0
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        n = 6'd32;
        if (v != 32'd0) begin
            t = v; n = 6'd0;
            if ((t & 32'h0000FFFF) == 32'd0) begin n = n + 6'd16; t = t >> 16; end
            if ((t & 32'h000000FF) == 32'd0) begin n = n + 6'd8;  t = t >> 8;  end
            if ((t & 32'h0000000F) == 32'd0) begin n = n + 6'd4;  t = t >> 4;  end
            if ((t & 32'h00000003) == 32'd0) begin n = n + 6'd2;  t = t >> 2;  end
            if ((t & 32'h00000001) == 32'd0) begin n = n + 6'd1; end
        end
        lo32 = n;
    end
endfunction

function [15:0] sat16;                      // saturating 16-bit unsigned add
    input [15:0] p, q;
    reg [16:0] t;
    begin
        t = {1'b0, p} + {1'b0, q};
        sat16 = (t > 17'hFFFF) ? 16'hFFFF : t[15:0];
    end
endfunction

function [7:0] sat8;                        // saturating 8-bit unsigned add
    input [7:0] p, q;
    reg [8:0] t;
    begin
        t = {1'b0, p} + {1'b0, q};
        sat8 = (t > 9'hFF) ? 8'hFF : t[7:0];
    end
endfunction

function [7:0] nsym;                        // ticks to symbols, saturated at 255
    input [15:0] ticks;
    input [5:0] sh;
    reg [15:0] t;
    begin
        t = ticks >> sh;
        nsym = (t > 16'd255) ? 8'hFF : t[7:0];
    end
endfunction

function [3:0] nlog2;                       // log2 of 2,4,8,16; 0 for anything else
    input [5:0] n;
    begin
        case (n)
            6'd2:  nlog2 = 4'd1;
            6'd4:  nlog2 = 4'd2;
            6'd8:  nlog2 = 4'd3;
            6'd16: nlog2 = 4'd4;
            default: nlog2 = 4'd0;
        endcase
    end
endfunction

reg [64:0] mpool;
reg [31:0] mev, mod, md0, md1, mil0, mil1, mcdata, mcil;
reg [5:0] mv0, mv1, mvu;
reg [7:0] ms0, ms1;
reg [5:0] mst;
reg [15:0] mbits;
reg mph, mphn, mlost, mres, mviol;
reg [63:0] mspread, mchan;
reg signed [31:0] mw0, mw1, mv0s, mv1s, mn0, mn1;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    mpool=65'd0; mev=32'd0; mod=32'd0; md0=32'd0; md1=32'd0;
mil0=32'd0; mil1=32'd0; mcdata=32'd0; mcil=32'd0;
mv0=6'd0; mv1=6'd0; mvu=6'd0; ms0=8'd0; ms1=8'd0; mst=6'd0; mbits=16'd0;
mph=1'b0; mphn=1'b0; mlost=1'b0; mres=1'b0; mviol=1'b0;
mw0=32'sd0; mw1=32'sd0; mv0s=32'sd0; mv1s=32'sd0; mn0=32'sd0; mn1=32'sd0;
mspread=64'd0; mchan=64'd0;
if (c[29:6] != 0) begin
    f = 1'b1;
end else begin
    if (c[31]) begin
        mres = 1'b1;
    end else begin
        mph = state_r[0];
    end
    if (c[30]) begin
        mspread = {32'd0, a};
        mspread = (mspread | (mspread << 16)) & 64'h0000FFFF0000FFFF;
        mspread = (mspread | (mspread << 8))  & 64'h00FF00FF00FF00FF;
        mspread = (mspread | (mspread << 4))  & 64'h0F0F0F0F0F0F0F0F;
        mspread = (mspread | (mspread << 2))  & 64'h3333333333333333;
        mspread = (mspread | (mspread << 1))  & 64'h5555555555555555;
        mchan = (mspread << 1) | (~mspread & 64'h5555555555555555);
        r = mchan[31:0];
        x = mchan[63:32];
        if (c[31]) state_n = 256'd0;
    end else begin
        mpool = {b, a, 1'b0};
        mpool[0] = mres ? 1'b0 : state_r[1];
        for (i = 0; i < 32; i = i + 1) begin
            mev[i] = mpool[i<<<1];
            mod[i] = mpool[(i<<<1) + 1];
        end
        md0 = (mev >> 1) | {mpool[64], 31'd0};
        md1 = mod;
        mil0 = ~(mod ^ md0);
        mil1 = ~(mev ^ mod);
        mv0 = pc32(mil0);
        mv1 = pc32(mil1);
        mcdata = mph ? md1 : md0;
        mcil   = mph ? mil1 : mil0;
        mvu    = mph ? mv1 : mv0;
        ms0 = mres ? 8'd0 : state_r[9:2];
        ms1 = mres ? 8'd0 : state_r[17:10];
        mw0 = $signed({24'd0, ms0});
        mw1 = $signed({24'd0, ms1});
        mv0s = $signed({26'd0, mv0});
        mv1s = $signed({26'd0, mv1});
        mn0 = mw0 + ((mv0s - mw0) >>> 2);
        if (mn0 < 32'sd0) mn0 = 32'sd0;
        else if (mn0 > 32'sd255) mn0 = 32'sd255;
        mn1 = mw1 + ((mv1s - mw1) >>> 2);
        if (mn1 < 32'sd0) mn1 = 32'sd0;
        else if (mn1 > 32'sd255) mn1 = 32'sd255;
        ms0 = mn0[7:0];
        ms1 = mn1[7:0];
        mphn = (ms1 < ms0) ? 1'b1 : ((ms0 < ms1) ? 1'b0 : mph);
        mviol = (mcil != 32'd0);
        mst = mres ? 6'd0 : state_r[23:18];
        if (mviol) begin
            f = 1'b1;
            if (mst != 6'h3F) mst = mst + 6'd1;
        end else begin
            mst = 6'd0;
        end
        if (c[5:0] != 6'd0 && mst >= c[5:0]) begin
            mlost = 1'b1;
            mst = 6'd0;
        end
        mbits = (mres ? 16'd0 : state_r[47:32]) + 16'd32;
        r = mcdata;
        x[5:0] = mv0;  x[11:6] = mv1;
        x[12] = mph;   x[13] = mphn;
        x[14] = mlost; x[15] = mres;
        x[21:16] = mst;
        x[29:22] = ms1 - ms0;
        state_n[0] = mphn;
        state_n[1] = b[31];
        state_n[9:2] = ms0;
        state_n[17:10] = ms1;
        state_n[23:18] = mst;
        state_n[31:24] = mres ? 8'd0 : sat8(state_r[31:24], {2'd0, mvu});
        state_n[47:32] = mbits;
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
