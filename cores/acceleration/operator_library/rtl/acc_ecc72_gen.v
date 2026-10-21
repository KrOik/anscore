// Authored kernel. See ip/ecc72_gen/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_ecc72_gen (
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
reg [63:0] ecc_d;
reg [7:0] ecc_chk, ecc_syn, ecc_rc;
reg ecc_cfg;
reg [11:0] ecc_seq;
localparam [63:0] EC_M0 = 64'hab55555556aaad5b;
localparam [63:0] EC_M1 = 64'hcd9999999b33366d;
localparam [63:0] EC_M2 = 64'hf1e1e1e1e3c3c78e;
localparam [63:0] EC_M3 = 64'h01fe01fe03fc07f0;
localparam [63:0] EC_M4 = 64'h01fffe0003fff800;
localparam [63:0] EC_M5 = 64'h01fffffffc000000;
localparam [63:0] EC_M6 = 64'hfe00000000000000;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    ecc_cfg = state_r[72];
ecc_d = {b, a};
if (c[31]) begin
    ecc_chk[0] = ^(ecc_d & EC_M0);
    ecc_chk[1] = ^(ecc_d & EC_M1);
    ecc_chk[2] = ^(ecc_d & EC_M2);
    ecc_chk[3] = ^(ecc_d & EC_M3);
    ecc_chk[4] = ^(ecc_d & EC_M4);
    ecc_chk[5] = ^(ecc_d & EC_M5);
    ecc_chk[6] = ^(ecc_d & EC_M6);
    ecc_chk[7] = (^ecc_d) ^ ^(ecc_chk[6:0]);
    state_n[63:0] = ecc_d;
    state_n[71:64] = ecc_chk;
    state_n[72] = 1'b1;
    if (state_r[100:93] != 8'hFF) state_n[100:93] = state_r[100:93] + 8'd1;
    r[7:0] = ecc_chk;
    r[16] = 1'b1;
end else if (!ecc_cfg) begin
    f = 1'b1;
    r[3:0] = 4'd1;
end else begin
    ecc_rc = c[7:0];
    ecc_syn[0] = ^(ecc_d & EC_M0) ^ ecc_rc[0];
    ecc_syn[1] = ^(ecc_d & EC_M1) ^ ecc_rc[1];
    ecc_syn[2] = ^(ecc_d & EC_M2) ^ ecc_rc[2];
    ecc_syn[3] = ^(ecc_d & EC_M3) ^ ecc_rc[3];
    ecc_syn[4] = ^(ecc_d & EC_M4) ^ ecc_rc[4];
    ecc_syn[5] = ^(ecc_d & EC_M5) ^ ecc_rc[5];
    ecc_syn[6] = ^(ecc_d & EC_M6) ^ ecc_rc[6];
    ecc_syn[7] = (^ecc_d) ^ ^(ecc_rc[6:0]) ^ ecc_rc[7];
    state_n[92:85] = ecc_syn;
    r[7:0] = ecc_syn;
    r[11] = 1'b1;
    if (ecc_syn == 8'd0) begin
        r[8] = 1'b1;
    end else if (ecc_syn[7]) begin
        r[9] = 1'b1;
        if (state_r[104:101] != 4'hF) state_n[104:101] = state_r[104:101] + 4'd1;
    end else begin
        r[10] = 1'b1;
        f = 1'b1;
        if (state_r[108:105] != 4'hF) state_n[108:105] = state_r[108:105] + 4'd1;
    end
end
ecc_seq = state_r[84:73] + 12'd1;
state_n[84:73] = ecc_seq;
x[11:0] = ecc_seq;
x[19:12] = state_n[92:85];
x[23:20] = state_n[104:101];
x[27:24] = state_n[108:105];
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
