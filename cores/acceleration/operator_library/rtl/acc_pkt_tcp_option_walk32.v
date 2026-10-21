// Authored kernel. See ip/pkt_tcp_option_walk32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pkt_tcp_option_walk32 (
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
reg [3:0] ptr, st0, nrec, offp, flg, win;
reg [4:0] kb;
reg [8:0] l, span;
reg [7:0] kind, lb, lastk, offk;
reg run, gen, cmpw, spl, multi;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ptr = c[3:0];
st0 = c[3:0];
win = b[2:0];
run = 1'b1; nrec = 4'd0; kb = 5'd0; flg = 4'd0; gen = 1'b0;
lastk = 8'd0; cmpw = 1'b0; spl = 1'b0; offk = 8'd0; offp = 4'd0;
for (idx = 0; idx < 4; idx = idx + 1) begin
    if (run) begin
        if ({1'b0, ptr} > {2'd0, win} || ptr > 4'd3) begin
            run = 1'b0; cmpw = 1'b1;
        end else begin
            multi = 1'b1;
            kind = a[{ptr, 3'd0} +: 8];
            nrec = nrec + 4'd1;
            lastk = kind;
            if (kind == 8'd0) begin
                kb[0] = 1'b1; ptr = ptr + 4'd1;
                run = 1'b0; cmpw = 1'b1; l = 9'd0;
            end else if (kind == 8'd1) begin
                kb[1] = 1'b1; ptr = ptr + 4'd1; l = 9'd0;
            end else begin
                if (kind == 8'd2) begin kb[2] = 1'b1; l = 9'd4; end
                else if (kind == 8'd3) begin kb[3] = 1'b1; l = 9'd3; end
                else if (kind == 8'd4) begin kb[4] = 1'b1; l = 9'd2; end
                else begin
                    gen = 1'b1; multi = 1'b0;
                    if (ptr == 4'd3) begin
                        flg[2] = 1'b1; spl = 1'b1; run = 1'b0; l = 9'd1;
                        if (offk == 8'd0) begin offk = kind; offp = ptr; end
                    end else begin
                        pl = {28'd0, ptr} + 32'd1;
                        lb = a[{pl[3:0], 3'd0} +: 8];
                        if (lb < 8'd2) begin
                            flg[0] = 1'b1; l = 9'd2;
                            if (offk == 8'd0) begin offk = kind; offp = ptr; end
                        end else l = {1'b0, lb};
                    end
                end
                span = {5'd0, ptr} + l;
                if (span > {2'd0, win}) begin
                    flg[1] = 1'b1; run = 1'b0; cmpw = 1'b1;
                    if (offk == 8'd0) begin offk = kind; offp = ptr; end
                end else if (span > 9'd4 && (multi || ptr != 4'd3)) begin
                    flg[2] = 1'b1; spl = 1'b1; run = 1'b0;
                end
                ptr = (span > 9'd15) ? 4'd15 : span[3:0];
            end
        end
    end
end
if (run) begin
    flg[3] = 1'b1;
    if (offk == 8'd0) begin offk = 8'hff; offp = ptr; end
end
x[3:0] = st0;
x[6:4] = win;
x[7] = (nrec == 4'd0);
x[8] = flg[0]; x[9] = flg[1]; x[10] = flg[2]; x[11] = flg[3];
x[12] = kb[0]; x[13] = kb[1];
x[14] = kb[2] | kb[3] | kb[4];
x[15] = gen;
x[19:16] = nrec;
x[23:20] = offp;
x[31:24] = offk;
r[3:0] = ptr;
r[7:4] = nrec;
r[12:8] = kb;
r[13] = gen;
r[14] = cmpw;
r[15] = spl;
r[29:22] = lastk;
f = flg[0] | flg[1] | flg[3];
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
