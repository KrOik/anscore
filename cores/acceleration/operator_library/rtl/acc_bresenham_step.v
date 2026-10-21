// Authored kernel. See ip/bresenham_step/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_bresenham_step (
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
    if(c[31]) begin
    if(a[31:16]!=0 || b[31:16]!=0 || c[30:1]!=0) begin
        f=1'b1; r=0; x=0; state_n=state_r;
    end else begin
        pa=a[7:0]; pb=a[15:8]; pc=b[7:0]; ph=b[15:8];
        pl=(pc>=pa) ? (pc-pa) : (pa-pc);
        mask=(ph>=pb) ? (ph-pb) : (pb-ph);
        state_n[11:0]=pa[11:0]; state_n[23:12]=pb[11:0];
        state_n[24]=(pc<pa); state_n[25]=(ph<pb);
        if(mask>pl) begin
            state_n[26]=1'b1; state_n[39:32]=mask[7:0]; state_n[47:40]=pl[7:0];
        end else begin
            state_n[26]=1'b0; state_n[39:32]=pl[7:0]; state_n[47:40]=mask[7:0];
        end
        state_n[27]=1'b1; state_n[28]=(state_n[39:32]==8'd0);
        state_n[57:48]=10'd0; state_n[65:58]=8'd0;
        state_n[68]=1'b0; state_n[69]=1'b0;
    end
end else begin
    if(a[31:8]!=0 || b!=0 || c[30:1]!=0 || !state_r[27] || state_r[28]) begin
        f=1'b1; r=0; x=0; state_n=state_r;
    end else begin
        temp=state_r[57:48]+{22'd0,state_r[47:40]};
        if(temp>={22'd0,state_r[39:32]}) begin
            temp=temp-{22'd0,state_r[39:32]}; sh=1; end
        else sh=0;
        state_n[57:48]=temp[9:0];
        state_n[65:58]=state_r[65:58]+8'd1;
        state_n[68]=1'b1; state_n[69]=sh;
        if(state_r[26]) begin
            if(state_r[25]) state_n[23:12]=state_r[23:12]-12'd1;
            else state_n[23:12]=state_r[23:12]+12'd1;
            if(sh) begin
                if(state_r[24]) state_n[11:0]=state_r[11:0]-12'd1;
                else state_n[11:0]=state_r[11:0]+12'd1;
            end
        end else begin
            if(state_r[24]) state_n[11:0]=state_r[11:0]-12'd1;
            else state_n[11:0]=state_r[11:0]+12'd1;
            if(sh) begin
                if(state_r[25]) state_n[23:12]=state_r[23:12]-12'd1;
                else state_n[23:12]=state_r[23:12]+12'd1;
            end
        end
        state_n[28]=(state_n[65:58]==state_r[39:32]);
    end
end
if(!f) begin
    r[11:0]=state_n[11:0]; r[23:12]=state_n[23:12];
    r[24]=state_n[68]; r[25]=state_n[69];
    r[26]=state_n[24]; r[27]=state_n[25]; r[28]=state_n[26];
    r[29]=((state_n[57:48]<<1)>={22'd0,state_n[39:32]});
    r[30]=state_n[28];
    r[31]=(state_n[39:32]==8'd0);
    x[7:0]=c[31] ? 8'd0 : a[7:0];
    x[15:8]=state_n[65:58];
    x[27:16]=state_n[57:48];
    x[28]=state_n[27]; x[29]=state_n[28]; x[30]=c[31];
    x[31]=(((state_n[57:48]<<1)=={22'd0,state_n[39:32]}));
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
