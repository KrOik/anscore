// Authored kernel. See ip/twiddle_index16/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_twiddle_index16 (
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
    if(a[31:20]!=0 || b[31:1]!=0 || c[31:1]!=0 || a[3:0]<4'd2 || a[3:0]>4'd12)
    f=1'b1;
else begin
    sh={28'd0, a[3:0]}; idx={28'd0, a[7:4]}; pa=a[19:8];
    pl=32'd1<<sh;
    pb=32'd0;
    if(c[0]==1'b0) begin
        if(idx>=sh || pa>=(pl>>1)) f=1'b1;
        else begin
            mask=(32'd1<<(sh-idx-1))-32'd1;
            pb=(pa & mask)<<idx;
        end
    end else begin
        if((sh&32'd1)!=32'd0 || {1'b0,idx}>=(sh>>1) || pa>=(pl>>2)) f=1'b1;
        else begin
            mask=(32'd1<<(sh-idx-idx-2))-32'd1;
            pb=(pa & mask)<<(idx+idx);
        end
    end
    if(!f) begin
        if(b[0]) pb=(pl-pb)&(pl-32'd1);
        pc=pb>>(sh-2);
        ph=pb&((32'd1<<(sh-2))-32'd1);
        temp=sh-2;
        r={13'd0, c[0], b[0], pc[1], (pc[0]^pc[1]), pc[0], pc[1:0],
           ph[11:0]};
        x={temp[3:0], a[3:0], a[7:4], pb[11:0]};
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
