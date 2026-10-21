// Authored kernel. See ip/lru8_victim/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_lru8_victim (
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
reg [3:0] lr_Wb, lr_nW, lr_Wa;
reg [7:0] lr_vm, lr_vmask, lr_row, lr_fold;
reg [2:0] lr_vb, lr_va, lr_way;
reg lr_cfg, lr_found, lr_ref, lr_qry;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    lr_cfg = state_r[76];
lr_Wb = state_r[75:72];
lr_vm = ((32'd1 << lr_Wb) - 32'd1) & 8'hff;
lr_vb = 3'd7;
lr_found = 1'b0;
for (i = 0; i < 8; i = i + 1) begin
    if (!lr_found && (i < lr_Wb) && ((state_r[(i << 3) +: 8] & lr_vm) == 8'd0)) begin
        lr_vb = i[2:0];
        lr_found = 1'b1;
    end
end
lr_way = 3'd0;
lr_ref = 1'b0;
lr_qry = 1'b0;
if (c[31]) begin
    lr_nW = c[3:0];
    if (lr_nW == 4'd0 || lr_nW > 4'd8) begin
        f = 1'b1;
        x[2:0] = 3'd4;
    end else begin
        lr_vmask = ((32'd1 << lr_nW) - 32'd1) & 8'hff;
        for (i = 0; i < 8; i = i + 1) begin
            if (i < lr_nW) state_n[(i << 3) +: 8] = (((32'd1 << i) - 32'd1) & lr_vmask);
            else state_n[(i << 3) +: 8] = 8'd0;
        end
        state_n[75:72] = lr_nW;
        state_n[76] = 1'b1;
        state_n[84:77] = 8'd0;
        state_n[92:85] = 8'd0;
    end
end else if (!lr_cfg) begin
    f = 1'b1;
    x[2:0] = 3'd1;
end else begin
    if (c[0]) begin
        lr_way = a[2:0];
        if (lr_way >= lr_Wb) begin
            f = 1'b1;
            x[2:0] = 3'd2;
        end else begin
            lr_ref = 1'b1;
            lr_vmask = ((32'd1 << lr_Wb) - 32'd1) & 8'hff;
            for (i = 0; i < 8; i = i + 1) begin
                if (i >= lr_Wb) lr_row = 8'd0;
                else if (i == lr_way) lr_row = lr_vmask & ~(8'd1 << lr_way);
                else lr_row = state_r[(i << 3) +: 8] & ~(8'd1 << lr_way);
                state_n[(i << 3) +: 8] = lr_row;
            end
            if (state_r[84:77] != 8'hFF) state_n[84:77] = state_r[84:77] + 8'd1;
        end
    end else begin
        lr_qry = 1'b1;
        if (state_r[92:85] != 8'hFF) state_n[92:85] = state_r[92:85] + 8'd1;
    end
end
if (!f) begin
    lr_Wa = state_n[75:72];
    lr_vm = ((32'd1 << lr_Wa) - 32'd1) & 8'hff;
    lr_va = 3'd7;
    lr_found = 1'b0;
    for (i = 0; i < 8; i = i + 1) begin
        if (!lr_found && (i < lr_Wa) && ((state_n[(i << 3) +: 8] & lr_vm) == 8'd0)) begin
            lr_va = i[2:0];
            lr_found = 1'b1;
        end
    end
    lr_fold = 8'd0;
    for (i = 0; i < 8; i = i + 1) lr_fold = lr_fold ^ state_n[(i << 3) +: 8];
    r[2:0] = lr_vb;
    r[5:3] = lr_va;
    r[8:6] = lr_ref ? lr_way : 3'd0;
    r[9] = lr_ref;
    r[10] = lr_qry;
    r[14:11] = lr_Wa;
    r[22:15] = lr_fold;
    r[26:23] = lr_Wb;
    x[3:0] = lr_Wa;
    x[11:4] = state_n[84:77];
    x[19:12] = state_n[92:85];
    x[22:20] = lr_vb;
    x[23] = state_n[76];
    x[31:24] = lr_fold;
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
