`timescale 1ns / 1ps
// tb_sm2_ecc: scalar mult / point add checks vs Python golden reference
module tb_sm2_ecc;

reg         clk = 0;
reg         rst_n = 0;
reg         start = 0;
reg  [1:0]  op;
reg  [255:0] k, ax, ay, bx, by;
wire        busy, done, inf, err;
wire [255:0] rx, ry;

integer errors = 0;
integer to;
// set to 1 to trace pcal FSM/op writes (diagnosed the FCPY concat-width bug)
localparam DEBUG_PCAL = 0;
integer wb_n = 0;
reg [3:0] pstate = 0;
always @(posedge clk) begin
    if (DEBUG_PCAL) begin
        pstate <= dut.U_pcal.state;
        if (dut.U_pcal.state == 4'd3 && dut.U_pcal.wcnt == 5'd7 && wb_n < 60) begin
            wb_n = wb_n + 1;
            $display("  WB%02d r=%0d v=%h", wb_n, dut.U_pcal.ins_op_r_0, dut.U_pcal.op_mod_0_r);
        end
        if (dut.U_pcal.state == 4'd5 && dut.U_pcal.wcnt == 5'd24)
            $display("  FCPY done");
        if (dut.U_pcal.state == 4'd4 && dut.U_pcal.wcnt == 5'd7)
            $display("  UWR id=%0d v=%h", dut.U_pcal.ins_updt_reg_id, dut.U_pcal.data_path_i);
        if (dut.U_pcal.state == 4'd2 && pstate == 4'd1 && wb_n < 60)
            $display("  CAL ins=%h a=%h b=%h", dut.U_pcal.ins_0_i, dut.U_pcal.op_a_reg, dut.U_pcal.op_b_reg);
        if (dut.U_pcal.rf_we && wb_n < 60)
            $display("  W st=%0d waddr=%0d wdata=%h", dut.U_pcal.state, dut.U_pcal.rf_waddr, dut.U_pcal.rf_wdata);
    end
end

sm2_ecc dut(
    .clk(clk), .rst_n(rst_n),
    .start(start), .op_i(op), .k_i(k),
    .ax_i(ax), .ay_i(ay), .bx_i(bx), .by_i(by),
    .busy_o(busy), .done_o(done), .inf_o(inf), .err_o(err),
    .rx_o(rx), .ry_o(ry)
);

always #5 clk = ~clk;

`ifdef ECC_DEBUG
// trace the first modular-inversion run in-context
integer invcyc = 0;
reg tracing = 0;
always @(posedge clk) begin
    if (dut.inv_start && !tracing) begin tracing = 1; invcyc = 0; end
    if (tracing && dut.g_inv.U_inv.busy && invcyc < 12) begin
        $display("INV iu=%h iv=%h ix=%h iy=%h st=%0d", dut.g_inv.U_inv.iu, dut.g_inv.U_inv.iv, dut.g_inv.U_inv.ix, dut.g_inv.U_inv.iy, dut.g_inv.U_inv.state);
        invcyc = invcyc + 1;
    end
    if (tracing && dut.g_inv.U_inv.done) begin
        $display("INV DONE r=%h", dut.g_inv.U_inv.r_o);
        tracing = 0;
    end
    if (tracing && dut.g_inv.U_inv.state == 4 && invcyc < 30)
        $strobe("CMP post u=%h v=%h", dut.g_inv.U_inv.iu, dut.g_inv.U_inv.iv);
end
`endif

task run_ecc;
    input [1:0]   o;
    input [255:0] kk;
    input [255:0] x1;
    input [255:0] y1;
    input [255:0] x2;
    input [255:0] y2;
    input [255:0] ex;
    input [255:0] ey;
    input         einf;
    input [127:0] tag;
begin
    op = o; k = kk; ax = x1; ay = y1; bx = x2; by = y2;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    to = 0;
    while (!done && to < 2000000) begin @(negedge clk); to = to + 1; end
    if (to >= 2000000) begin
        errors = errors + 1;
        $display("ECC TIMEOUT tag=%h", tag);
    end else if (einf) begin
        if (inf && !err) $display("ECC PASS tag=%h (inf)", tag);
        else begin errors = errors + 1;
            $display("ECC FAIL tag=%h inf=%b err=%b", tag, inf, err); end
    end else if (err) begin
        errors = errors + 1;
        $display("ECC FAIL tag=%h err=1", tag);
    end else if (rx === ex && ry === ey) begin
        $display("ECC PASS tag=%h rx=%h", tag, rx);
    end else begin
        errors = errors + 1;
        $display("ECC FAIL tag=%h", tag);
        $display("  got  %h %h", rx, ry);
        $display("  want %h %h", ex, ey);
        $display("  dbg x2 %h", dut.var_x2);
        $display("  dbg y2 %h", dut.var_y2);
        $display("  dbg bX2 %h", {dut.U_pcal.rf_a[7][31:0],dut.U_pcal.rf_a[6][31:0],dut.U_pcal.rf_a[5][31:0],dut.U_pcal.rf_a[4][31:0],dut.U_pcal.rf_a[3][31:0],dut.U_pcal.rf_a[2][31:0],dut.U_pcal.rf_a[1][31:0],dut.U_pcal.rf_a[0][31:0]});
        $display("  dbg bZ2 %h", {dut.U_pcal.rf_a[23][31:0],dut.U_pcal.rf_a[22][31:0],dut.U_pcal.rf_a[21][31:0],dut.U_pcal.rf_a[20][31:0],dut.U_pcal.rf_a[19][31:0],dut.U_pcal.rf_a[18][31:0],dut.U_pcal.rf_a[17][31:0],dut.U_pcal.rf_a[16][31:0]});
        $display("  dbg bX0 %h", {dut.U_pcal.rf_a[55][31:0],dut.U_pcal.rf_a[54][31:0],dut.U_pcal.rf_a[53][31:0],dut.U_pcal.rf_a[52][31:0],dut.U_pcal.rf_a[51][31:0],dut.U_pcal.rf_a[50][31:0],dut.U_pcal.rf_a[49][31:0],dut.U_pcal.rf_a[48][31:0]});
        $display("  dbg bY0 %h", {dut.U_pcal.rf_a[63][31:0],dut.U_pcal.rf_a[62][31:0],dut.U_pcal.rf_a[61][31:0],dut.U_pcal.rf_a[60][31:0],dut.U_pcal.rf_a[59][31:0],dut.U_pcal.rf_a[58][31:0],dut.U_pcal.rf_a[57][31:0],dut.U_pcal.rf_a[56][31:0]});
        $display("  dbg bZ0 %h", {dut.U_pcal.rf_a[71][31:0],dut.U_pcal.rf_a[70][31:0],dut.U_pcal.rf_a[69][31:0],dut.U_pcal.rf_a[68][31:0],dut.U_pcal.rf_a[67][31:0],dut.U_pcal.rf_a[66][31:0],dut.U_pcal.rf_a[65][31:0],dut.U_pcal.rf_a[64][31:0]});
        $display("  dbg z2 %h", dut.var_z2);
        $display("  dbg cx1 %h", 256'h0);
        $display("  dbg inv %h", dut.inv_r);
        $display("  dbg t0  %h", 256'h0);
        $display("  dbg ia  %h", dut.inv_a);
        $display("  dbg iu  %h", dut.g_inv.U_inv.iu);
        $display("  dbg iv  %h", dut.g_inv.U_inv.iv);
        $display("  dbg ix  %h", dut.g_inv.U_inv.ix);
        $display("  dbg iy  %h", dut.g_inv.U_inv.iy);
    end
    repeat (4) @(negedge clk);
end
endtask

localparam [255:0] GX = 256'h32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7;
localparam [255:0] GY = 256'hBC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0;
localparam [255:0] DA = 256'h128B2FA8BD433C6C068C8D803DFF79792A519A55171B1B650C23661D15897263;
localparam [255:0] PAX = 256'hD5548C7825CBB56150A3506CD57464AF8A1AE0519DFAF3C58221DC810CAF28DD;
localparam [255:0] PAY = 256'h921073768FE3D59CE54E79A49445CF73FED23086537027264D168946D479533E;
localparam [255:0] KS = 256'h6CB28D99385C175C94F94E934817663FC176D925DD72B727260DBAAE1FB2F96F;
localparam [255:0] KGX = 256'hF6A687AB5744D5CBBA1CF93D8436416F75C3AEC3D762814D565314AFF57A89F9;
localparam [255:0] KGY = 256'hF1B8EE0541740565491E44043DE53CF5BBEDD61333071260DFC5783F47A7B981;
localparam [255:0] G2X = 256'h56CEFD60D7C87C000D58EF57FA73BA4D9C0DFA08C08A7331495C2E1DA3F2BD52;
localparam [255:0] G2Y = 256'h31B7E7E6CC8189F668535CE0F8EAF1BD6DE84C182F6C8E716F780D3A970A23C3;
localparam [255:0] G3X = 256'hA97F7CD4B3C993B4BE2DAA8CDB41E24CA13F6BD945302244E26918F1D0509EBF;
localparam [255:0] G3Y = 256'h530B5DD88C688EF5CCC5CEC08A72150F7C400EE5CD045292AAACDD037458F6E6;

initial begin
    repeat (10) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // k=1 -> G
    run_ecc(2'd0, 256'd1, 0,0, 0,0, GX, GY, 0, 128'h01);
    // k=2 -> 2G (single double)
    run_ecc(2'd0, 256'd2, 0,0, 0,0, G2X, G2Y, 0, 128'h00);
    // k=3 -> 3G (double + add)
    run_ecc(2'd0, 256'd3, 0,0, 0,0, G3X, G3Y, 0, 128'h07);
    // dA*G -> PA
    run_ecc(2'd0, DA, 0,0, 0,0, PAX, PAY, 0, 128'h02);
    // k_sig*G -> known
    run_ecc(2'd0, KS, 0,0, 0,0, KGX, KGY, 0, 128'h03);
    // 3*PA via PMUL_P
    run_ecc(2'd1, 256'd3, PAX, PAY, 0,0,
            256'hA14D2A2E25BC48701E22F909D52F86B56FF6CE6039EEBE5ABA09D9B77D577E18,
            256'hC5E476CCAE3DE85259D02F60DFEA49D3ED402D6614A54D56D111FBDAA855B425, 0, 128'h04);
    // G + 2G -> 3G via PADD
    run_ecc(2'd2, 0, GX, GY, G2X, G2Y, G3X, G3Y, 0, 128'h05);
    // k=0 -> infinity
    run_ecc(2'd0, 256'd0, 0,0, 0,0, 0, 0, 1, 128'h06);

    if (errors == 0) $display("SM2_ECC ALL PASS");
    else             $display("SM2_ECC ERRORS=%0d", errors);
    $finish;
end

endmodule
