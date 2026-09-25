// Authored kernel. See ip/fifo_wm/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_fifo_wm (
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
reg [7:0] fw_D, fw_L, fw_after, fw_pk, fw_push, fw_pop, fw_cD;
reg [3:0] fw_ovf, fw_und;
reg fw_cfg, fw_pushacc, fw_popacc;
reg [2:0] fw_cause;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    fw_cfg = state_r[48];
fw_D = state_r[7:0];
fw_L = state_r[15:8];
fw_pk = state_r[23:16];
fw_push = state_r[31:24];
fw_pop = state_r[39:32];
fw_ovf = state_r[43:40];
fw_und = state_r[47:44];
fw_after = fw_L;
fw_pushacc = 1'b0;
fw_popacc = 1'b0;
fw_cause = 3'd0;
if (c[31]) begin
    fw_cD = c[7:0];
    if (fw_cD == 8'd0) begin
        fw_cause = 3'd4;
    end else begin
        state_n[7:0] = fw_cD;
        state_n[15:8] = 8'd0;
        state_n[23:16] = 8'd0;
        state_n[31:24] = 8'd0;
        state_n[39:32] = 8'd0;
        state_n[43:40] = 4'd0;
        state_n[47:44] = 4'd0;
        state_n[48] = 1'b1;
    end
end else if (!fw_cfg) begin
    fw_cause = 3'd1;
end else begin
    if (a[1]) begin
        if (fw_after != 8'd0) begin
            fw_after = fw_after - 8'd1;
            fw_popacc = 1'b1;
            if (fw_pop != 8'hFF) state_n[39:32] = fw_pop + 8'd1;
        end else begin
            if (fw_cause == 3'd0) fw_cause = 3'd3;
            if (fw_und != 4'hF) state_n[47:44] = fw_und + 4'd1;
        end
    end
    if (a[0]) begin
        if (fw_after < fw_D) begin
            fw_after = fw_after + 8'd1;
            fw_pushacc = 1'b1;
            if (fw_push != 8'hFF) state_n[31:24] = fw_push + 8'd1;
        end else begin
            if (fw_cause == 3'd0) fw_cause = 3'd2;
            if (fw_ovf != 4'hF) state_n[43:40] = fw_ovf + 4'd1;
        end
    end
    state_n[15:8] = fw_after;
    if (fw_after > fw_pk) state_n[23:16] = fw_after;
end
if (fw_cause != 3'd0) begin
    f = 1'b1;
    x[2:0] = fw_cause;
end else begin
    r[7:0] = fw_L;
    r[15:8] = fw_after;
    r[16] = (fw_L == 8'd0);
    r[17] = (fw_L == fw_D);
    r[18] = (fw_L == 8'd1);
    r[19] = (fw_L == (fw_D - 8'd1));
    r[20] = (fw_L >= (fw_D >> 1));
    r[21] = fw_pushacc;
    r[22] = fw_popacc;
    x[7:0] = fw_D;
    x[15:8] = (fw_after > fw_pk) ? fw_after : fw_pk;
    x[23:16] = (fw_pushacc && (fw_push != 8'hFF)) ? (fw_push + 8'd1) : fw_push;
    x[31:24] = (fw_popacc && (fw_pop != 8'hFF)) ? (fw_pop + 8'd1) : fw_pop;
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
