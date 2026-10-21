`timescale 1ns / 1ps
// tb_sm2_top.v — SM2 protocol-engine testbench, GM/T 0003.5 Annex A vectors
module tb_sm2_top;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg         start;
reg  [2:0]  op;
reg         p_we;
reg  [3:0]  p_sel;
reg  [255:0] p_data;
reg         m_we;
reg  [8:0]  m_addr;
reg  [7:0]  m_data;
reg  [8:0]  o_addr;
wire [7:0]  o_data;
wire        busy, done, err, valid;
wire [255:0] rx, ry, sr, ss, c3;

sm2_top dut(
    .clk(clk), .rst_n(rst_n),
    .start(start), .op_i(op),
    .p_we(p_we), .p_sel(p_sel), .p_data(p_data),
    .m_we(m_we), .m_addr(m_addr), .m_data(m_data),
    .o_addr(o_addr), .o_data(o_data),
    .busy_o(busy), .done_o(done), .err_o(err), .valid_o(valid),
    .rx_o(rx), .ry_o(ry), .sr_o(sr), .ss_o(ss), .c3_o(c3)
);

// GM/T vectors
localparam [255:0] DA  = 256'h128B2FA8BD433C6C068C8D803DFF79792A519A55171B1B650C23661D15897263;
localparam [255:0] PAX = 256'hD5548C7825CBB56150A3506CD57464AF8A1AE0519DFAF3C58221DC810CAF28DD;
localparam [255:0] PAY = 256'h921073768FE3D59CE54E79A49445CF73FED23086537027264D168946D479533E;
localparam [255:0] KK  = 256'h6CB28D99385C175C94F94E934817663FC176D925DD72B727260DBAAE1FB2F96F;
localparam [255:0] EE  = 256'h10D51CB90C0C0522E94875A2BEA7AB72299EBE7192E64EFE0573B1C77110E5C9;
localparam [255:0] RR  = 256'h077BA4656350DAEEA3656EE042DDECE22D5E8DCA4882CB20080AD26E2CB62E9F;
localparam [255:0] SS  = 256'h2BF329F4AFF86EEE0F924888DDE20BF12A21B638A3B0F1FCA70395C4BE00D0AC;
localparam [255:0] DB  = 256'h1649AB77A00637BD5E2EFE283FBF353534AA7F7CB89463F208DDBC2920BB0DA0;
localparam [255:0] PBX = 256'h191BFF8148006EEA72D857CB974DB9F4903B3CA3655D8D597AD4663F5044DCB1;
localparam [255:0] PBY = 256'hE2F7888AF1FCD8C653A8059CD2F379855389F71A7709E2C1EE1E914C855EF119;
localparam [255:0] KE  = 256'h4C62EEFD6ECFC2B95B92FD6C3D9575148AFA17425546D49018E5388D49DD7B4F;
localparam [255:0] C1X = 256'h11C88AE04CEC1BA554D03D5B5970333A83585826C2A985DE5520D9E934389EFB;
localparam [255:0] C1Y = 256'h84B52D344FB21AA8EA38A4940C8332692B8D4DA2393549212EAFDC0F11CA5C9C;
localparam [255:0] C3V = 256'h0137E757931553826A245A0BAEF73E2A693A861C6E93509CDA65C2B97C0AB2ED;

// "encryption standard" (19 bytes)
reg [7:0] msg19 [0:18];
// its ciphertext C2 (19 bytes)
reg [7:0] c2v [0:18];

integer errors = 0;
integer to;
integer i;

`ifdef FEED_DEBUG
always @(posedge clk) begin
    if (dut.h_vld && dut.h_rdy)
        $display("FEED d=%h vb=%h lst=%b pos=%0d tot=%0d mode=%0d", dut.h_d, dut.h_vb, dut.h_lst, dut.f_pos, dut.f_total, dut.f_mode);
    if (dut.f_active && !dut.h_vld)
        $display("LATCH fpos=%0d fmode=%0d m0=%h fgo=%b", dut.f_pos, dut.f_mode, dut.m_buf[0], dut.feed_go);
    if (dut.h_rvld)
        $display("DIGEST res=%h", dut.h_res);
    if (dut.U_sm3.pad_otpt_vld)
        $display("PADOUT d=%h lst=%b vr1=%b ena=%b pst=%h est=%h", dut.U_sm3.pad_otpt_d, dut.U_sm3.pad_otpt_lst,
                 dut.U_sm3.U_sm3_pad_core.msg_inpt_vld_r1, dut.U_sm3.pad_otpt_ena,
                 dut.U_sm3.U_sm3_pad_core.state, dut.U_sm3.U_sm3_expnd_core.state);
    if (dut.mn_done)
        $display("MN done r=%h state=%0d", dut.mn_r, dut.state);
    if (dut.iv_done)
        $display("IV done r=%h err=%b state=%0d", dut.iv_r, dut.iv_err, dut.state);
    if (dut.ecc_done)
        $display("ECC done rx=%h inf=%b err=%b state=%0d", dut.ecc_rx[127:0], dut.ecc_inf, dut.ecc_err, dut.state);
end
`endif

task lp(input [3:0] sel, input [255:0] data);
begin
    @(negedge clk); p_sel = sel; p_data = data; p_we = 1;
    @(negedge clk); p_we = 0;
end
endtask

task set_msg(input [8:0] n);
integer j;
begin
    for (j = 0; j < n; j = j + 1) begin
        @(negedge clk); m_addr = j[8:0]; m_data = msg19[j]; m_we = 1;
    end
    @(negedge clk); m_we = 0;
    lp(4'd9, {247'd0, n});
end
endtask

task set_c2(input [8:0] n);
integer j;
begin
    for (j = 0; j < n; j = j + 1) begin
        @(negedge clk); m_addr = j[8:0]; m_data = c2v[j]; m_we = 1;
    end
    @(negedge clk); m_we = 0;
    lp(4'd9, {247'd0, n});
end
endtask

task run_op(input [2:0] o);
begin
    @(negedge clk); op = o; start = 1;
    @(negedge clk); start = 0;
    to = 0;
    while (!done && to < 3000000) begin @(posedge clk); to = to + 1; end
    if (to >= 3000000) begin
        errors = errors + 1;
        $display("TOP TIMEOUT op=%0d", o);
    end
end
endtask

task check256(input [255:0] got, input [255:0] exp, input [127:0] tag);
begin
    if (got === exp) $display("PASS %s", tag);
    else begin
        errors = errors + 1;
        $display("FAIL %s", tag);
        $display("  got  %h", got);
        $display("  want %h", exp);
    end
end
endtask

task check_obuf_msg(input [8:0] n, input [127:0] tag);
integer j;
reg bad;
begin
    bad = 0;
    for (j = 0; j < n; j = j + 1) begin
        o_addr = j[8:0];
        #1;
        if (o_data !== msg19[j]) begin
            bad = 1;
            $display("  obuf[%0d] got %h want %h", j, o_data, msg19[j]);
        end
    end
    if (!bad) $display("PASS %s", tag);
    else begin errors = errors + 1; $display("FAIL %s", tag); end
end
endtask

task check_obuf_c2(input [8:0] n, input [127:0] tag);
integer j;
reg bad;
begin
    bad = 0;
    for (j = 0; j < n; j = j + 1) begin
        o_addr = j[8:0];
        #1;
        if (o_data !== c2v[j]) begin
            bad = 1;
            $display("  obuf[%0d] got %h want %h", j, o_data, c2v[j]);
        end
    end
    if (!bad) $display("PASS %s", tag);
    else begin errors = errors + 1; $display("FAIL %s", tag); end
end
endtask

initial begin
    // msg = "encryption standard" = 656e6372797074696f6e207374616e64617264
    msg19[0]=8'h65; msg19[1]=8'h6e; msg19[2]=8'h63; msg19[3]=8'h72;
    msg19[4]=8'h79; msg19[5]=8'h70; msg19[6]=8'h74; msg19[7]=8'h69;
    msg19[8]=8'h6f; msg19[9]=8'h6e; msg19[10]=8'h20; msg19[11]=8'h73;
    msg19[12]=8'h74; msg19[13]=8'h61; msg19[14]=8'h6e; msg19[15]=8'h64;
    msg19[16]=8'h61; msg19[17]=8'h72; msg19[18]=8'h64;
    // C2 = d76b28b93a4b3765997a3bbc58f998731d0aa2
    c2v[0]=8'hd7; c2v[1]=8'h6b; c2v[2]=8'h28; c2v[3]=8'hb9;
    c2v[4]=8'h3a; c2v[5]=8'h4b; c2v[6]=8'h37; c2v[7]=8'h65;
    c2v[8]=8'h99; c2v[9]=8'h7a; c2v[10]=8'h3b; c2v[11]=8'hbc;
    c2v[12]=8'h58; c2v[13]=8'hf9; c2v[14]=8'h98; c2v[15]=8'h73;
    c2v[16]=8'h1d; c2v[17]=8'h0a; c2v[18]=8'ha2;

    start = 0; op = 0; p_we = 0; p_sel = 0; p_data = 0;
    m_we = 0; m_addr = 0; m_data = 0; o_addr = 0;
    repeat (6) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);

    // ---- KEYGEN: PA = dA*G ----
    lp(4'd0, DA);
    run_op(3'd1);
    check256(rx, PAX, "KEYGEN.x");
    check256(ry, PAY, "KEYGEN.y");

    // ---- SIGN(dA, e, k) ----
    lp(4'd2, EE);
    lp(4'd1, KK);
    run_op(3'd2);
    check256(sr, RR, "SIGN.r");
    check256(ss, SS, "SIGN.s");

    // ---- VERIFY(PA, e, r, s) -> valid ----
    lp(4'd3, PAX); lp(4'd4, PAY);
    lp(4'd5, RR);  lp(4'd6, SS);
    run_op(3'd3);
    if (valid) $display("PASS VERIFY.good");
    else begin errors = errors + 1; $display("FAIL VERIFY.good"); end

    // ---- VERIFY bad r -> invalid ----
    lp(4'd5, RR + 256'd1);
    run_op(3'd3);
    if (!valid) $display("PASS VERIFY.bad");
    else begin errors = errors + 1; $display("FAIL VERIFY.bad"); end

    // ---- HASH("encryption standard" first 3 bytes "enc")? use full msg ----
    // OP_HASH over the 19-byte message buffer
    set_msg(9'd19);
    run_op(3'd0);
    // SM3("encryption standard") -- filled in below after sim if unknown
    $display("INFO HASH got %h", c3);

    // ---- ENC(PB, kenc, msg19) ----
    lp(4'd3, PBX); lp(4'd4, PBY); lp(4'd1, KE);
    run_op(3'd4);
    check256(rx, C1X, "ENC.C1x");
    check256(ry, C1Y, "ENC.C1y");
    check256(c3, C3V, "ENC.C3");
    check_obuf_c2(9'd19, "ENC.C2");

    // ---- DEC(dB, C1, C2, C3) ----
    lp(4'd0, DB);
    lp(4'd7, C1X); lp(4'd8, C1Y);
    lp(4'd6, C3V);
    set_c2(9'd19);
    run_op(3'd5);
    if (valid) $display("PASS DEC.valid");
    else begin errors = errors + 1; $display("FAIL DEC.valid"); end
    check_obuf_msg(9'd19, "DEC.M");

    // ---- DEC with corrupted C3 -> invalid ----
    lp(4'd6, C3V ^ 256'h1);
    set_c2(9'd19);
    run_op(3'd5);
    if (!valid) $display("PASS DEC.badC3");
    else begin errors = errors + 1; $display("FAIL DEC.badC3"); end

    if (errors == 0) $display("SM2_TOP ALL PASS");
    else             $display("SM2_TOP ERRORS=%0d", errors);
    $finish;
end
endmodule
