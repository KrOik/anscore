// Authored kernel. See ip/comm_crc32_frame/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_comm_crc32_frame (
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
// Generated parallel CRC-32 fold: one XOR tree per output bit and per
// byte length. The Python model uses the serial reference, so RTL and
// model agreeing is the proof that the matrix is the right one.
wire [2:0] nb = c[2:0];
wire [31:0] cs = c[31] ? b[31:0] : state_r[31:0];
wire [31:0] cr1;
assign cr1[0] = ^({cs & 32'h00000104, a & 32'h00000004});
assign cr1[1] = ^({cs & 32'h00000209, a & 32'h00000009});
assign cr1[2] = ^({cs & 32'h00000413, a & 32'h00000013});
assign cr1[3] = ^({cs & 32'h00000826, a & 32'h00000026});
assign cr1[4] = ^({cs & 32'h0000104D, a & 32'h0000004D});
assign cr1[5] = ^({cs & 32'h0000209A, a & 32'h0000009A});
assign cr1[6] = ^({cs & 32'h00004030, a & 32'h00000030});
assign cr1[7] = ^({cs & 32'h00008061, a & 32'h00000061});
assign cr1[8] = ^({cs & 32'h000100C2, a & 32'h000000C2});
assign cr1[9] = ^({cs & 32'h00020080, a & 32'h00000080});
assign cr1[10] = ^({cs & 32'h00040004, a & 32'h00000004});
assign cr1[11] = ^({cs & 32'h00080008, a & 32'h00000008});
assign cr1[12] = ^({cs & 32'h00100011, a & 32'h00000011});
assign cr1[13] = ^({cs & 32'h00200023, a & 32'h00000023});
assign cr1[14] = ^({cs & 32'h00400046, a & 32'h00000046});
assign cr1[15] = ^({cs & 32'h0080008C, a & 32'h0000008C});
assign cr1[16] = ^({cs & 32'h0100001D, a & 32'h0000001D});
assign cr1[17] = ^({cs & 32'h0200003B, a & 32'h0000003B});
assign cr1[18] = ^({cs & 32'h04000077, a & 32'h00000077});
assign cr1[19] = ^({cs & 32'h080000EE, a & 32'h000000EE});
assign cr1[20] = ^({cs & 32'h100000D8, a & 32'h000000D8});
assign cr1[21] = ^({cs & 32'h200000B4, a & 32'h000000B4});
assign cr1[22] = ^({cs & 32'h4000006C, a & 32'h0000006C});
assign cr1[23] = ^({cs & 32'h800000D8, a & 32'h000000D8});
assign cr1[24] = ^({cs & 32'h000000B5, a & 32'h000000B5});
assign cr1[25] = ^({cs & 32'h0000006F, a & 32'h0000006F});
assign cr1[26] = ^({cs & 32'h000000DF, a & 32'h000000DF});
assign cr1[27] = ^({cs & 32'h000000BA, a & 32'h000000BA});
assign cr1[28] = ^({cs & 32'h00000071, a & 32'h00000071});
assign cr1[29] = ^({cs & 32'h000000E3, a & 32'h000000E3});
assign cr1[30] = ^({cs & 32'h000000C3, a & 32'h000000C3});
assign cr1[31] = ^({cs & 32'h00000082, a & 32'h00000082});
wire [31:0] cr2;
assign cr2[0] = ^({cs & 32'h000104D1, a & 32'h000004D1});
assign cr2[1] = ^({cs & 32'h000209A2, a & 32'h000009A2});
assign cr2[2] = ^({cs & 32'h00041344, a & 32'h00001344});
assign cr2[3] = ^({cs & 32'h00082688, a & 32'h00002688});
assign cr2[4] = ^({cs & 32'h00104D10, a & 32'h00004D10});
assign cr2[5] = ^({cs & 32'h00209A20, a & 32'h00009A20});
assign cr2[6] = ^({cs & 32'h00403091, a & 32'h00003091});
assign cr2[7] = ^({cs & 32'h00806122, a & 32'h00006122});
assign cr2[8] = ^({cs & 32'h0100C245, a & 32'h0000C245});
assign cr2[9] = ^({cs & 32'h0200805A, a & 32'h0000805A});
assign cr2[10] = ^({cs & 32'h04000464, a & 32'h00000464});
assign cr2[11] = ^({cs & 32'h080008C8, a & 32'h000008C8});
assign cr2[12] = ^({cs & 32'h10001191, a & 32'h00001191});
assign cr2[13] = ^({cs & 32'h20002323, a & 32'h00002323});
assign cr2[14] = ^({cs & 32'h40004646, a & 32'h00004646});
assign cr2[15] = ^({cs & 32'h80008C8C, a & 32'h00008C8C});
assign cr2[16] = ^({cs & 32'h00001DC9, a & 32'h00001DC9});
assign cr2[17] = ^({cs & 32'h00003B93, a & 32'h00003B93});
assign cr2[18] = ^({cs & 32'h00007726, a & 32'h00007726});
assign cr2[19] = ^({cs & 32'h0000EE4D, a & 32'h0000EE4D});
assign cr2[20] = ^({cs & 32'h0000D84B, a & 32'h0000D84B});
assign cr2[21] = ^({cs & 32'h0000B446, a & 32'h0000B446});
assign cr2[22] = ^({cs & 32'h00006C5C, a & 32'h00006C5C});
assign cr2[23] = ^({cs & 32'h0000D8B8, a & 32'h0000D8B8});
assign cr2[24] = ^({cs & 32'h0000B5A1, a & 32'h0000B5A1});
assign cr2[25] = ^({cs & 32'h00006F92, a & 32'h00006F92});
assign cr2[26] = ^({cs & 32'h0000DF24, a & 32'h0000DF24});
assign cr2[27] = ^({cs & 32'h0000BA99, a & 32'h0000BA99});
assign cr2[28] = ^({cs & 32'h000071E3, a & 32'h000071E3});
assign cr2[29] = ^({cs & 32'h0000E3C6, a & 32'h0000E3C6});
assign cr2[30] = ^({cs & 32'h0000C35C, a & 32'h0000C35C});
assign cr2[31] = ^({cs & 32'h00008268, a & 32'h00008268});
wire [31:0] cr3;
assign cr3[0] = ^({cs & 32'h0104D101, a & 32'h0004D101});
assign cr3[1] = ^({cs & 32'h0209A203, a & 32'h0009A203});
assign cr3[2] = ^({cs & 32'h04134407, a & 32'h00134407});
assign cr3[3] = ^({cs & 32'h0826880E, a & 32'h0026880E});
assign cr3[4] = ^({cs & 32'h104D101D, a & 32'h004D101D});
assign cr3[5] = ^({cs & 32'h209A203B, a & 32'h009A203B});
assign cr3[6] = ^({cs & 32'h40309176, a & 32'h00309176});
assign cr3[7] = ^({cs & 32'h806122EC, a & 32'h006122EC});
assign cr3[8] = ^({cs & 32'h00C245D8, a & 32'h00C245D8});
assign cr3[9] = ^({cs & 32'h00805AB1, a & 32'h00805AB1});
assign cr3[10] = ^({cs & 32'h00046462, a & 32'h00046462});
assign cr3[11] = ^({cs & 32'h0008C8C5, a & 32'h0008C8C5});
assign cr3[12] = ^({cs & 32'h0011918A, a & 32'h0011918A});
assign cr3[13] = ^({cs & 32'h00232315, a & 32'h00232315});
assign cr3[14] = ^({cs & 32'h0046462B, a & 32'h0046462B});
assign cr3[15] = ^({cs & 32'h008C8C56, a & 32'h008C8C56});
assign cr3[16] = ^({cs & 32'h001DC9AC, a & 32'h001DC9AC});
assign cr3[17] = ^({cs & 32'h003B9359, a & 32'h003B9359});
assign cr3[18] = ^({cs & 32'h007726B2, a & 32'h007726B2});
assign cr3[19] = ^({cs & 32'h00EE4D64, a & 32'h00EE4D64});
assign cr3[20] = ^({cs & 32'h00D84BC8, a & 32'h00D84BC8});
assign cr3[21] = ^({cs & 32'h00B44690, a & 32'h00B44690});
assign cr3[22] = ^({cs & 32'h006C5C21, a & 32'h006C5C21});
assign cr3[23] = ^({cs & 32'h00D8B843, a & 32'h00D8B843});
assign cr3[24] = ^({cs & 32'h00B5A187, a & 32'h00B5A187});
assign cr3[25] = ^({cs & 32'h006F920E, a & 32'h006F920E});
assign cr3[26] = ^({cs & 32'h00DF241C, a & 32'h00DF241C});
assign cr3[27] = ^({cs & 32'h00BA9938, a & 32'h00BA9938});
assign cr3[28] = ^({cs & 32'h0071E370, a & 32'h0071E370});
assign cr3[29] = ^({cs & 32'h00E3C6E0, a & 32'h00E3C6E0});
assign cr3[30] = ^({cs & 32'h00C35CC0, a & 32'h00C35CC0});
assign cr3[31] = ^({cs & 32'h00826880, a & 32'h00826880});
wire [31:0] cr4;
assign cr4[0] = ^({cs & 32'h04D101DF, a & 32'h04D101DF});
assign cr4[1] = ^({cs & 32'h09A203BE, a & 32'h09A203BE});
assign cr4[2] = ^({cs & 32'h1344077D, a & 32'h1344077D});
assign cr4[3] = ^({cs & 32'h26880EFA, a & 32'h26880EFA});
assign cr4[4] = ^({cs & 32'h4D101DF4, a & 32'h4D101DF4});
assign cr4[5] = ^({cs & 32'h9A203BE9, a & 32'h9A203BE9});
assign cr4[6] = ^({cs & 32'h3091760D, a & 32'h3091760D});
assign cr4[7] = ^({cs & 32'h6122EC1A, a & 32'h6122EC1A});
assign cr4[8] = ^({cs & 32'hC245D835, a & 32'hC245D835});
assign cr4[9] = ^({cs & 32'h805AB1B5, a & 32'h805AB1B5});
assign cr4[10] = ^({cs & 32'h046462B5, a & 32'h046462B5});
assign cr4[11] = ^({cs & 32'h08C8C56A, a & 32'h08C8C56A});
assign cr4[12] = ^({cs & 32'h11918AD4, a & 32'h11918AD4});
assign cr4[13] = ^({cs & 32'h232315A9, a & 32'h232315A9});
assign cr4[14] = ^({cs & 32'h46462B53, a & 32'h46462B53});
assign cr4[15] = ^({cs & 32'h8C8C56A6, a & 32'h8C8C56A6});
assign cr4[16] = ^({cs & 32'h1DC9AC92, a & 32'h1DC9AC92});
assign cr4[17] = ^({cs & 32'h3B935924, a & 32'h3B935924});
assign cr4[18] = ^({cs & 32'h7726B249, a & 32'h7726B249});
assign cr4[19] = ^({cs & 32'hEE4D6493, a & 32'hEE4D6493});
assign cr4[20] = ^({cs & 32'hD84BC8F9, a & 32'hD84BC8F9});
assign cr4[21] = ^({cs & 32'hB446902D, a & 32'hB446902D});
assign cr4[22] = ^({cs & 32'h6C5C2184, a & 32'h6C5C2184});
assign cr4[23] = ^({cs & 32'hD8B84309, a & 32'hD8B84309});
assign cr4[24] = ^({cs & 32'hB5A187CC, a & 32'hB5A187CC});
assign cr4[25] = ^({cs & 32'h6F920E46, a & 32'h6F920E46});
assign cr4[26] = ^({cs & 32'hDF241C8C, a & 32'hDF241C8C});
assign cr4[27] = ^({cs & 32'hBA9938C7, a & 32'hBA9938C7});
assign cr4[28] = ^({cs & 32'h71E37051, a & 32'h71E37051});
assign cr4[29] = ^({cs & 32'hE3C6E0A3, a & 32'hE3C6E0A3});
assign cr4[30] = ^({cs & 32'hC35CC098, a & 32'hC35CC098});
assign cr4[31] = ^({cs & 32'h826880EF, a & 32'h826880EF});
wire [31:0] crx = (nb == 3'd4) ? cr4 : (nb == 3'd3) ? cr3 : (nb == 3'd2) ? cr2 : cr1;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(nb == 3'd0 || nb > 3'd4 || c[29:3] != 27'd0) f = 1'b1;
else begin
    pa = crx;
    r = ~pa;
    temp = {24'd0, state_r[39:32]} + {29'd0, nb};
    x[7:0] = c[30] ? 8'd0 : (temp > 32'd255) ? 8'hFF : temp[7:0];
    x[10:8] = nb;
    x[11] = c[31];
    x[12] = c[30];
    x[13] = c[30] ? 1'b0 : (state_r[39:32] == 8'hFF);
    x[31:14] = 18'd0;
    if(c[30] && pa != 32'hDEBB20E3) f = 1'b1;
    state_n = c[30] ? {216'd0, 8'd0, 32'hFFFFFFFF}
                      : {216'd0, x[7:0], pa};
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
