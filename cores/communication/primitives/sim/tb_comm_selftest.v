`timescale 1ns/1ps
// Runs comm_selftest to completion and prints every unit digest.
// Also dumps the raw folded byte streams for golden-model diffing.
module tb_comm_selftest;

`ifndef UNIT_EN
`define UNIT_EN 16'h001F
`endif

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

wire all_done, all_pass, any_fail;
wire [15:0] done_mask, pass_mask;
reg  [4:0]  sel = 5'd0;
localparam [15:0] UEN = `UNIT_EN;
wire [31:0] dq;

comm_selftest #(.UNIT_EN(`UNIT_EN)) dut (
    .clk(clk), .rst_n(rst_n),
    .all_done(all_done), .all_pass(all_pass), .any_fail(any_fail),
    .digest_sel(sel), .digest_q(dq),
    .done_mask(done_mask), .pass_mask(pass_mask)
);

reg [8*5-1:0] names [0:15];
initial begin
    names[0]="URX"; names[1]="SPIM"; names[2]="I2CM"; names[3]="AXIL";
    names[4]="FIFO";
    names[5]="--"; names[6]="--"; names[7]="--"; names[8]="--";
    names[9]="--"; names[10]="--"; names[11]="--"; names[12]="--";
    names[13]="--"; names[14]="--"; names[15]="--";
end

integer i;
integer timeout;

// ---------------------------------------------------------------------------
// Stream dumps for offline golden-model comparison
// ---------------------------------------------------------------------------
integer fd_urx, fd_spi, fd_i2c, fd_axil, fd_fifo;
initial begin
    fd_urx  = $fopen("sim/dump_urx.txt",  "w");
    fd_spi  = $fopen("sim/dump_spi.txt",  "w");
    fd_i2c  = $fopen("sim/dump_i2c.txt",  "w");
    fd_axil = $fopen("sim/dump_axil.txt", "w");
    fd_fifo = $fopen("sim/dump_fifo.txt", "w");
end

// uart: dump each received byte + framing flag (what the digest folds)
always @(posedge clk) begin
    if (rst_n && dut.ce && UEN[0] && dut.u_state == 4'd2 && dut.u_rx_valid) begin
        $fwrite(fd_urx, "%02x %b\n", dut.u_rx_data, dut.u_rx_ferr);
    end
    // spi: dump master rx word and slave captured word per transfer
    if (rst_n && dut.ce && UEN[1] && dut.s_state == 4'd1 && dut.s_m_done) begin
        $fwrite(fd_spi, "rx %08x\n", dut.s_rxw);
    end
`ifdef DUMP_SPI_MISO
    // debug only: raw miso bit at every sclk rising edge (needs g_u1 to exist)
    if (rst_n && UEN[1] && dut.s_sclk && !dut.g_u1.u_spis.sclk_d) begin
        $fwrite(fd_spi, "miso %b\n", dut.s_miso);
    end
`endif
    if (rst_n && dut.ce && UEN[1] && dut.s_state == 4'd3 && dut.s_capvalid) begin
        $fwrite(fd_spi, "cap %08x %0d\n", dut.s_capdata, dut.s_capbits);
    end
    // i2c: dump each read byte, each status, each captured byte
    if (rst_n && dut.ce && UEN[2] && dut.i_rx_valid && !dut.i_rxack) begin
        $fwrite(fd_i2c, "rx %02x\n", dut.i_rx_data);
    end
    if (rst_n && dut.ce && UEN[2] && dut.i_state == 4'd2) begin
        $fwrite(fd_i2c, "st %b\n", dut.i_nack);
    end
    if (rst_n && dut.ce && UEN[2] && dut.i_state == 4'd4) begin
        $fwrite(fd_i2c, "cnt %0d cap %02x\n", dut.i_slv_cnt, dut.i_cap_byte);
    end
    // axil: dump bresp / rdata+rresp
    if (rst_n && dut.ce && UEN[3] && dut.a_state == 4'd2 && dut.a_bvalid) begin
        $fwrite(fd_axil, "bresp %02x\n", dut.a_bresp);
    end
    if (rst_n && dut.ce && UEN[3] && dut.a_state == 4'd5) begin
        $fwrite(fd_axil, "rdata %08x rresp %02x\n", dut.a_rdata, dut.a_rresp);
    end
end

// fifo: dump each read byte (rdclk domain event; f_rdcap = dout-valid cycle)
always @(posedge dut.rdclk) begin
    if (rst_n && UEN[4] && dut.f_rdcap) begin
        $fwrite(fd_fifo, "%02x\n", dut.f_dout);
    end
end

initial begin
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    timeout = 0;
    while (!all_done && timeout < 5000000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end
    if (!all_done) begin
        $display("SELFTEST TIMEOUT done_mask=%04x", done_mask);
    end
    repeat (64) @(posedge clk);
    for (i = 0; i < 16; i = i + 1) begin
        sel = i[4:0];
        #1;
        $display("UNIT %0d %-4s done=%b pass=%b digest=%08x",
                 i, names[i], done_mask[i], pass_mask[i], dq);
    end
    $display("SELFTEST %s done_mask=%04x pass_mask=%04x",
             all_pass ? "ALL-PASS" : "DONE-WITH-FAIL", done_mask, pass_mask);
    if (all_done && all_pass && !any_fail) $display("RESULT: PASS");
    else $display("RESULT: FAIL");
    $fclose(fd_urx); $fclose(fd_spi); $fclose(fd_i2c);
    $fclose(fd_axil); $fclose(fd_fifo);
    $finish;
end

endmodule
