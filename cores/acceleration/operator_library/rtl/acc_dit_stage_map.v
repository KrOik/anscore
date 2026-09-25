// Authored kernel. See ip/dit_stage_map/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_dit_stage_map (
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
function [11:0] q_brev;
    input [11:0] v; input [3:0] bl; integer qk; reg [11:0] qacc;
    begin
        qacc = 12'd0;
        for(qk=0; qk<12; qk=qk+1) qacc = (qk<bl) ? ((qacc<<1) | v[qk]) : qacc;
        q_brev = qacc;
    end
endfunction
reg [31:0] q_pos0, q_pos1, q_stride, q_rank, q_bank;
reg [1:0] q_md;
reg q_flag;
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
    pl=32'd1<<sh; q_md=b[1:0]; q_rank=(32'd1<<idx)-32'd1;
    q_stride=32'd1<<idx; q_pos0=32'd0; q_pos1=32'd0; q_bank=32'd0;
    pb=32'd0; pc=32'd0; ph=32'd0; temp=(32'd1<<c[3:0])-32'd1;
    mask=32'd0; q_flag=1'b0;
    if(q_md==2'd3 || idx>=sh) f=1'b1;
    else if(q_md==2'd0) begin
        if(pa>=(pl>>1)) f=1'b1;
        else begin
            q_pos0=((pa>>idx)<<(idx+32'd1))|(pa&q_rank);
            q_pos1=q_pos0|q_stride;
            mask=(pa&q_rank)<<(sh-idx-32'd1);
            r[11:0]=q_brev(q_pos0[11:0], a[3:0]);
            r[23:12]=q_brev(q_pos1[11:0], a[3:0]);
            r[24]=((q_pos0^q_pos1)&temp)==32'd0; r[25]=1'b1;
            r[27:26]=q_md; r[31:28]=a[7:4];
            x[11:0]=mask[11:0]; x[23:12]=q_pos0[11:0];
            x[27:24]=q_brev(pa[11:0], a[3:0])&4'hf;
            x[31:28]=c[3:0];
        end
    end else if(q_md==2'd1) begin
        if(pa>=pl) f=1'b1;
        else begin
            pb=q_brev(pa[11:0], a[3:0]);
            pc=(pl-pa)&(pl-32'd1);
            q_pos1=q_brev(pc[11:0], a[3:0]);
            r[11:0]=pb; r[23:12]=q_pos1[11:0];
            r[24]=(pb==q_pos1); r[25]=1'b1;
            r[27:26]=q_md; r[31:28]=a[7:4];
            x[11:0]=pc[11:0]; x[23:12]=pa[11:0];
            q_bank=pa&temp; x[27:24]=q_bank[3:0]; x[31:28]=c[3:0];
        end
    end else begin
        if(idx>=(sh-32'd1) || pa>=(pl>>2)) f=1'b1;
        else begin
            q_pos0=((pa>>idx)<<(idx+32'd2))|(pa&q_rank);
            pb=q_brev(q_pos0[11:0], a[3:0]);
            pc=q_brev(q_pos0+q_stride, a[3:0]);
            ph=q_brev(q_pos0+(q_stride<<32'd1), a[3:0]);
            mask=q_brev(q_pos0+((q_stride<<32'd1)+q_stride), a[3:0]);
            r[11:0]=pb; r[23:12]=pc;
            x[11:0]=ph; x[23:12]=mask;
            q_flag=((q_stride&temp)==32'd0);
            r[24]=q_flag; r[25]=1'b1;
            r[27:26]=q_md; r[31:28]=a[7:4];
            q_bank=pb&temp; x[27:24]=q_bank[3:0]; x[31:28]=c[3:0];
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
