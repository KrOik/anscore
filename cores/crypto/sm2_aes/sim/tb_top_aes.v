`timescale 1ns / 1ps
// tb_top_aes: UART-level test of image A (top_aes).
//   'H' ping -> "OK"
//   'A' + 'E' AES-128 enc/dec -> FIPS-197; AES-256 enc
//   'M' 3 "abc" -> 'D' + SM3 digest
module tb_top_aes;

reg         clk, rst_n, rxd;
wire        txd;
wire [5:0]  led;

top_aes dut(
    .clk(clk), .rst_n(rst_n),
    .uart_rx(rxd), .uart_tx(txd), .led(led)
);

always #18.5 clk = ~clk;

localparam BIT = 37.0 * 234;

integer errors = 0;
integer rxn   = 0;
reg [7:0] rxc [0:255];

always @(negedge txd) begin : txcap
    reg [7:0] sh;
    integer k;
    if (rst_n) begin
        #(BIT * 1.5);
        for (k = 0; k < 8; k = k + 1) begin
            sh[k] = txd;
            #(BIT);
        end
        rxc[rxn] = sh;
        rxn = rxn + 1;
    end
end

task send(input [7:0] b);
integer k;
begin
    rxd = 0; #(BIT);
    for (k = 0; k < 8; k = k + 1) begin
        rxd = b[k]; #(BIT);
    end
    rxd = 1; #(BIT);
end
endtask

task send_blk(input [8*40-1:0] bytes, input integer n);
integer k;
begin
    for (k = 0; k < n; k = k + 1)
        send(bytes[8*(n-1-k) +: 8]);
end
endtask

task wait_rxn(input integer n);
integer k;
begin
    for (k = 0; k < 500000 && rxn < n; k = k + 1) #(BIT/4);
end
endtask

always @(posedge clk) begin
    if (dut.h_vld)
        $display("  FEED d=%h vb=%h lst=%b", dut.h_d, dut.h_vb, dut.h_lst);
end

integer i;
reg [127:0] aesres;
reg [255:0] digest;

initial begin
    clk = 0; rst_n = 0; rxd = 1;
    repeat (10) @(posedge clk);
    rst_n = 1;
    #(BIT * 4);

    // ---- ping ----------------------------------------------------------------
    send(8'h48);
    wait_rxn(2);
    if (rxc[0] !== 8'h4F || rxc[1] !== 8'h4B) begin
        errors = errors + 1;
        $display("FAIL ping: %h %h", rxc[0], rxc[1]);
    end else $display("PASS ping OK");

    // ---- AES-128 encrypt -------------------------------------------------------
    send_blk({8'h41, 8'h00,
              128'h000102030405060708090a0b0c0d0e0f,
              128'h0}, 34);
    wait_rxn(3);
    if (rxc[2] !== 8'h61) begin
        errors = errors + 1; $display("FAIL aes-key ack: %h", rxc[2]);
    end else $display("PASS aes-key ack");

    send_blk({8'h45, 8'h01, 128'h00112233445566778899aabbccddeeff}, 18);
    wait_rxn(19);
    aesres = {rxc[3], rxc[4], rxc[5], rxc[6], rxc[7], rxc[8], rxc[9], rxc[10],
              rxc[11], rxc[12], rxc[13], rxc[14], rxc[15], rxc[16], rxc[17], rxc[18]};
    if (aesres !== 128'h69c4e0d86a7b0430d8cdb78070b4c55a) begin
        errors = errors + 1;
        $display("FAIL aes-128 enc: %h", aesres);
    end else $display("PASS aes-128 enc %h", aesres);

    // ---- AES-128 decrypt (same key) ---------------------------------------------
    send_blk({8'h45, 8'h00, 128'h69c4e0d86a7b0430d8cdb78070b4c55a}, 18);
    wait_rxn(35);
    aesres = {rxc[19], rxc[20], rxc[21], rxc[22], rxc[23], rxc[24], rxc[25], rxc[26],
              rxc[27], rxc[28], rxc[29], rxc[30], rxc[31], rxc[32], rxc[33], rxc[34]};
    if (aesres !== 128'h00112233445566778899aabbccddeeff) begin
        errors = errors + 1;
        $display("FAIL aes-128 dec: %h", aesres);
    end else $display("PASS aes-128 dec %h", aesres);

    // ---- SM3("abc") via 'M' ------------------------------------------------------
    send_blk({8'h4D, 8'h00, 8'h03, 8'h61, 8'h62, 8'h63}, 6);
    wait_rxn(68);
    if (rxc[35] !== 8'h44) begin
        errors = errors + 1;
        $display("FAIL sm3 hdr: %h", rxc[35]);
    end
    digest = {rxc[36], rxc[37], rxc[38], rxc[39], rxc[40], rxc[41], rxc[42], rxc[43],
              rxc[44], rxc[45], rxc[46], rxc[47], rxc[48], rxc[49], rxc[50], rxc[51],
              rxc[52], rxc[53], rxc[54], rxc[55], rxc[56], rxc[57], rxc[58], rxc[59],
              rxc[60], rxc[61], rxc[62], rxc[63], rxc[64], rxc[65], rxc[66], rxc[67]};
    if (digest !== 256'h66C7F0F462EEEDD9D1F2D46BDC10E4E24167C4875CF2F7A2297DA02B8F4BA8E0) begin
        errors = errors + 1;
        $display("FAIL sm3(abc): %h", digest);
    end else $display("PASS sm3(abc) %h", digest[127:0]);

    if (errors == 0) $display("TOP_AES ALL PASS");
    else             $display("TOP_AES ERRORS=%0d", errors);
    $finish;
end

initial begin
    #(37.0 * 40 * 1000 * 1000);
    $display("TIMEOUT rxn=%0d", rxn);
    $finish;
end

endmodule
