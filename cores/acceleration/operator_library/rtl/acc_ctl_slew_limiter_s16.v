// Authored kernel. See ip/ctl_slew_limiter_s16/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ctl_slew_limiter_s16 (
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
    if (lane == 0) begin pa = c[13:0]; pb = c[29:16]; end
    else begin pa = b[13:0]; pb = b[29:16]; end
    if (c[31]) begin
        r[lane*16 +: 16] = a[lane*16 +: 16];
        state_n[lane*16 +: 16] = a[lane*16 +: 16];
        x[6] = 1'b1;
        x[4+lane] = 1'b1;
    end
    else if (c[30]) begin
        r[lane*16 +: 16] = state_r[lane*16 +: 16];
        state_n[lane*16 +: 16] = state_r[lane*16 +: 16];
        x[7] = 1'b1;
        x[4+lane] = (a[lane*16 +: 16] == state_r[lane*16 +: 16]);
    end
    else if ((pa == 0) && (pb == 0)) begin
        r[lane*16 +: 16] = state_r[lane*16 +: 16];
        state_n[lane*16 +: 16] = state_r[lane*16 +: 16];
        x[8+lane] = 1'b1;
        f = 1'b1;
    end
    else begin
        swide = $signed({{48{a[lane*16+15]}}, a[lane*16 +: 16]})
              - $signed({{48{state_r[lane*16+15]}}, state_r[lane*16 +: 16]});
        if (swide > $signed({32'd0, pa})) begin
            swide2 = $signed({{48{state_r[lane*16+15]}}, state_r[lane*16 +: 16]})
                   + $signed({32'd0, pa});
            r[lane*16 +: 16] = swide2[15:0];
            state_n[lane*16 +: 16] = swide2[15:0];
            x[lane] = 1'b1;
            f = 1'b1;
        end
        else if (swide < -$signed({32'd0, pb})) begin
            swide2 = $signed({{48{state_r[lane*16+15]}}, state_r[lane*16 +: 16]})
                   - $signed({32'd0, pb});
            r[lane*16 +: 16] = swide2[15:0];
            state_n[lane*16 +: 16] = swide2[15:0];
            x[2+lane] = 1'b1;
            f = 1'b1;
        end
        else begin
            r[lane*16 +: 16] = a[lane*16 +: 16];
            state_n[lane*16 +: 16] = a[lane*16 +: 16];
            x[4+lane] = 1'b1;
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
                result<=r; aux<=x; fault<=f; state_r<=state_n;
            end
        end
    end
end
endmodule
