`timescale 1ns / 1ps
// Board-top smoke test: drives the UART command protocol at the pin level.
//   'H' ping -> "OK"
//   'A' + 'E' AES-128 enc -> FIPS-197 result
//   'W'+'L'+'G'(op0) +'Q'(4) -> SM3("abc")
module tb_top_uart;

reg         clk, rst_n, rxd;
wire        txd;
wire [5:0]  led;

top dut(
    .clk(clk), .rst_n(rst_n),
    .uart_rx(rxd), .uart_tx(txd), .led(led)
);

always #18.5 clk = ~clk;   // ~27 MHz

localparam BIT = 37.0 * 234;   // 115200 baud @ 27 MHz (234 clk/bit)

integer errors = 0;
integer rxn   = 0;
reg [7:0] rxc [0:255];         // captured TX bytes

// ---------------- TX byte capture ---------------------------------------------
// wait start bit, sample 8 data bits at mid-bit
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

// ---------------- UART send task ----------------------------------------------
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

task expect(input [7:0] b, input [127:0] tag);
integer k;
begin
    for (k = 0; k < 200; k = k + 1) begin
        if (rxn > 0) k = 200;
        else #(BIT);
    end
    if (rxn == 0) begin
        errors = errors + 1;
        $display("FAIL %h: no response", tag);
    end else if (rxc[rxn-1] !== b) begin
        errors = errors + 1;
        $display("FAIL %h: got %h exp %h", tag, rxc[rxn-1], b);
    end else
        $display("PASS %h = %h", tag, b);
end
endtask

task wait_rxn(input integer n);
integer k;
begin
    for (k = 0; k < 500000 && rxn < n; k = k + 1) #(BIT/4);
end
endtask

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

    // ---- AES-128 encrypt -----------------------------------------------------
    // 'A' klen=0 key=000102...0f (+16B pad)
    send_blk({8'h41, 8'h00,
              128'h000102030405060708090a0b0c0d0e0f,
              128'h0}, 34);
    wait_rxn(3);
    if (rxc[2] !== 8'h61) begin
        errors = errors + 1; $display("FAIL aes-key ack: %h", rxc[2]);
    end else $display("PASS aes-key ack");

    // 'E' enc blk=00112233...ff
    send_blk({8'h45, 8'h01, 128'h00112233445566778899aabbccddeeff}, 18);
    wait_rxn(19);
    aesres = {rxc[3], rxc[4], rxc[5], rxc[6], rxc[7], rxc[8], rxc[9], rxc[10],
              rxc[11], rxc[12], rxc[13], rxc[14], rxc[15], rxc[16], rxc[17], rxc[18]};
    if (aesres !== 128'h69c4e0d86a7b0430d8cdb78070b4c55a) begin
        errors = errors + 1;
        $display("FAIL aes-128 enc: %h", aesres);
    end else $display("PASS aes-128 enc %h", aesres);

    // ---- SM2 OP_HASH of "abc" ------------------------------------------------
    // 'W' 0 'a' / 'W' 1 'b' / 'W' 2 'c'
    send_blk({8'h57, 8'h00, 8'h61}, 3); wait_rxn(20);
    send_blk({8'h57, 8'h01, 8'h62}, 3); wait_rxn(21);
    send_blk({8'h57, 8'h02, 8'h63}, 3); wait_rxn(22);
    // 'L' sel=9 msg_len=3 (32B big-endian)
    send_blk({8'h4C, 8'h09, 248'h0, 8'h03}, 34); wait_rxn(23);
    // 'G' op=0 (OP_HASH)
    send_blk({8'h47, 8'h00}, 2);
    wait_rxn(25);
    if (rxc[23] !== 8'h44 || rxc[24][1:0] !== 2'b00) begin
        errors = errors + 1;
        $display("FAIL hash-done: %h %h", rxc[23], rxc[24]);
    end else $display("PASS hash-done");
    // 'Q' sel=4 -> c3 = digest
    send_blk({8'h51, 8'h04}, 2);
    wait_rxn(57);
    digest = {rxc[25], rxc[26], rxc[27], rxc[28], rxc[29], rxc[30], rxc[31], rxc[32],
              rxc[33], rxc[34], rxc[35], rxc[36], rxc[37], rxc[38], rxc[39], rxc[40],
              rxc[41], rxc[42], rxc[43], rxc[44], rxc[45], rxc[46], rxc[47], rxc[48],
              rxc[49], rxc[50], rxc[51], rxc[52], rxc[53], rxc[54], rxc[55], rxc[56]};
    if (digest !== 256'h66C7F0F462EEEDD9D1F2D46BDC10E4E24167C4875CF2F7A2297DA02B8F4BA8E0) begin
        errors = errors + 1;
        $display("FAIL sm3(abc): %h", digest);
    end else $display("PASS sm3(abc) %h", digest[127:0]);

    if (errors == 0) $display("TOP_UART ALL PASS");
    else             $display("TOP_UART ERRORS=%0d", errors);
    $finish;
end

initial begin
    #(37.0 * 40 * 1000 * 1000);
    $display("TIMEOUT rxn=%0d", rxn);
    $finish;
end

endmodule
