// Authored kernel. See ip/ctl_pid_form_s16/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ctl_pid_form_s16 (
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
    for (lane = 0; lane < 2; lane = lane + 1) begin
    temp = a[lane*16 +: 16];
    mask = state_r[lane*16 +: 16];
    pa = {{16{temp[15]}}, temp[15:0]};
    pb = {{16{mask[15]}}, mask[15:0]};
    if (c[31]) begin
        swide2 = $signed(pa) - $signed(pb);
        if (swide2 < 0) swide2 = -swide2;
        if (swide2 >= (64'sd1 <<< (32'd15 - b[18:16]))) begin
            x[4+lane] = 1'b1;
            f = 1'b1;
        end
    end
    swide = $signed(pa) - $signed(pb);
    if (c[31]) swide = 0;
    sh = b[11:8];
    swide = swide >>> sh;
    swide2 = swide;
    if (swide != 0) x[6+lane] = 1'b1;
    if (c[31]) swide = 0;
    else swide = $signed(state_r[32 + 32*lane +: 32]);
    if (!c[30]) begin
        sh = b[7:4];
        swide = swide + ($signed(pa) >>> sh);
        if (swide > 64'sd8388607) begin
            swide = 64'sd8388607;
            x[lane] = 1'b1;
        end
        else if (swide < -64'sd8388607) begin
            swide = -64'sd8388607;
            x[lane] = 1'b1;
        end
    end
    state_n[32 + 32*lane +: 32] = swide[31:0];
    if (swide[31]) x[8+lane] = 1'b1;
    swide2 = swide2 + swide;
    sh = b[3:0];
    swide2 = swide2 + ($signed(pa) >>> sh);
    sh = b[15:12];
    swide2 = swide2 >>> sh;
    if (swide2 > 64'sd32767) begin
        swide2 = 64'sd32767;
        x[2+lane] = 1'b1;
    end
    else if (swide2 < -64'sd32768) begin
        swide2 = -64'sd32768;
        x[2+lane] = 1'b1;
    end
    r[lane*16 +: 16] = swide2[15:0];
    state_n[lane*16 +: 16] = temp[15:0];
end
x[10] = c[31];
x[11] = c[30];
x[27:16] = b[15:4];
if ((state_n[63:32] == 0) && (state_n[95:64] == 0)) x[12] = 1'b1;
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
