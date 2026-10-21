// Authored kernel. See ip/stockham_addr/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_stockham_addr (
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
reg [31:0] q_base, q_stride, q_rank, q_leg2, q_leg3, q_e, q_bank, q_bmask;
reg [1:0] q_md;
reg q_clash;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(a[31:20]!=0 || b[31:2]!=0 || c[31:4]!=0 || a[3:0]<4'd2 || a[3:0]>4'd12)
    f=1'b1;
else begin
    sh={28'd0, a[3:0]}; idx={28'd0, a[7:4]}; pa=a[19:8];
    pl=32'd1<<sh; q_md=b[1:0]; q_bmask=(32'd1<<c[3:0])-32'd1;
    pb=32'd0; pc=32'd0; ph=32'd0; q_base=32'd0; q_stride=32'd0;
    q_rank=32'd0; q_leg2=32'd0; q_leg3=32'd0; q_e=32'd0; q_clash=1'b0;
    if(q_md==2'd2 || q_md==2'd3) f=1'b1;
    else begin
        q_rank=(32'd1<<idx)-32'd1;
        q_stride=32'd1<<idx;
        if(q_md==2'd0) begin
            if(idx>=sh || pa>=(pl>>1)) f=1'b1;
            else begin
                q_base=((pa>>idx)<<(idx+32'd1))|(pa&q_rank);
                pb=q_base; pc=q_base|q_stride;
                q_e=(pa&q_rank)<<(sh-idx-32'd1);
                q_clash=((q_stride&q_bmask)==32'd0);
                r[11:0]=pb[11:0]; r[23:12]=pc[11:0]; r[24]=q_clash;
                r[25]=1'b1; r[27:26]=q_md; r[31:28]=a[7:4];
                x[11:0]=q_e[11:0]; x[23:12]=q_stride[11:0];
                q_bank=pb&q_bmask;
                x[27:24]=q_bank[3:0]; x[31:28]=c[3:0];
            end
        end else begin
            if(idx>=(sh-32'd1) || pa>=(pl>>2)) f=1'b1;
            else begin
                q_base=((pa>>idx)<<(idx+32'd2))|(pa&q_rank);
                pb=q_base; pc=q_base+q_stride;
                q_leg2=q_base+(q_stride<<32'd1);
                q_leg3=q_base+((q_stride<<32'd1)+q_stride);
                q_clash=((q_stride&q_bmask)==32'd0);
                r[11:0]=pb[11:0]; r[23:12]=pc[11:0]; r[24]=q_clash;
                r[25]=1'b1; r[27:26]=q_md; r[31:28]=a[7:4];
                x[11:0]=q_leg2[11:0]; x[23:12]=q_leg3[11:0];
                q_bank=pb&q_bmask;
                x[27:24]=q_bank[3:0]; x[31:28]=c[3:0];
            end
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
                result<=r; aux<=x; fault<=f;
            end
        end
    end
end
endmodule
