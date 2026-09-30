`timescale 1ns / 1ps
// tb_top_sm2: UART-level test of image B (top_sm2).
//   'H' ping -> "OK"
//   'L' k=dA, 'G' PMUL_G -> Jacobian (x,y,z); TB converts to affine via
//   sm2_mod_inv + sm2_modn helpers and checks vs GM/T PA.
//   k=1 -> affine base point; k=0 -> inf flag.
module tb_top_sm2;

reg         clk, rst_n, rxd;
wire        txd;
wire [5:0]  led;

top_sm2 dut(
    .clk(clk), .rst_n(rst_n),
    .uart_rx(rxd), .uart_tx(txd), .led(led)
);

always #18.5 clk = ~clk;

localparam BIT = 37.0 * 234;
localparam [255:0] P256 = 256'hFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF;

localparam [255:0] GX  = 256'h32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7;
localparam [255:0] GY  = 256'hBC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0;
localparam [255:0] DA  = 256'h128B2FA8BD433C6C068C8D803DFF79792A519A55171B1B650C23661D15897263;
localparam [255:0] PAX = 256'hD5548C7825CBB56150A3506CD57464AF8A1AE0519DFAF3C58221DC810CAF28DD;
localparam [255:0] PAY = 256'h921073768FE3D59CE54E79A49445CF73FED23086537027264D168946D479533E;

integer errors = 0;
integer rxn   = 0;
reg [7:0] rxc [0:255];

// ---------------- TB helper engines: mod inverse + mod mul --------------------
reg         hi_start;
reg  [255:0] hi_a, hi_m;
wire        hi_busy, hi_done, hi_err;
wire [255:0] hi_r;

sm2_mod_inv H_INV(
    .clk(clk), .rst_n(rst_n),
    .start(hi_start), .a_i(hi_a), .m_i(hi_m),
    .busy(hi_busy), .done(hi_done), .err(hi_err), .r_o(hi_r)
);

reg          hm_start;
reg  [1:0]   hm_op;
reg  [255:0] hm_a, hm_b, hm_m;
wire         hm_busy, hm_done;
wire [255:0] hm_r;

sm2_modn H_MODN(
    .clk(clk), .rst_n(rst_n),
    .start(hm_start), .op_i(hm_op),
    .a_i(hm_a), .b_i(hm_b), .m_i(hm_m),
    .busy(hm_busy), .done(hm_done), .r_o(hm_r)
);

task modinv(input [255:0] a, output [255:0] r);
integer to;
begin
    @(negedge clk);
    hi_a = a; hi_m = P256; hi_start = 1;
    @(negedge clk); hi_start = 0;
    to = 0;
    while (!hi_done && to < 100000) begin @(posedge clk); to = to + 1; end
    r = hi_r;
end
endtask

task modmul(input [255:0] a, input [255:0] b, output [255:0] r);
integer to;
begin
    @(negedge clk);
    hm_a = a; hm_b = b; hm_m = P256; hm_op = 2'd2; hm_start = 1;
    @(negedge clk); hm_start = 0;
    to = 0;
    while (!hm_done && to < 100000) begin @(posedge clk); to = to + 1; end
    r = hm_r;
end
endtask

// ---------------- TX byte capture ---------------------------------------------
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

// ---------------- UART send ----------------------------------------------------
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

// read 32B result: 'Q' sel -> assemble into qout
task get_q(input [7:0] sel, output [255:0] qout);
integer base;
begin
    base = rxn;
    send_blk({8'h51, sel}, 2);
    wait_rxn(base + 32);
    qout = {rxc[base],    rxc[base+1],  rxc[base+2],  rxc[base+3],
            rxc[base+4],  rxc[base+5],  rxc[base+6],  rxc[base+7],
            rxc[base+8],  rxc[base+9],  rxc[base+10], rxc[base+11],
            rxc[base+12], rxc[base+13], rxc[base+14], rxc[base+15],
            rxc[base+16], rxc[base+17], rxc[base+18], rxc[base+19],
            rxc[base+20], rxc[base+21], rxc[base+22], rxc[base+23],
            rxc[base+24], rxc[base+25], rxc[base+26], rxc[base+27],
            rxc[base+28], rxc[base+29], rxc[base+30], rxc[base+31]};
end
endtask

integer i;
reg [255:0] digest;
reg [255:0] jx, jy, jz;
reg [255:0] zi, z2i, z3i, xa, ya;
integer   base;

initial begin
    clk = 0; rst_n = 0; rxd = 1;
    hi_start = 0; hi_a = 0; hi_m = 0;
    hm_start = 0; hm_op = 0; hm_a = 0; hm_b = 0; hm_m = 0;
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

    // ---- PMUL_G(k=dA) -> Jacobian ----------------------------------------------
    send_blk({8'h4C, 8'h00, DA}, 34);          // 'L' sel=0 k=dA
    wait_rxn(3);
    if (rxc[2] !== 8'h6C) begin
        errors = errors + 1; $display("FAIL load ack: %h", rxc[2]);
    end else $display("PASS load-k ack");

    send_blk({8'h47, 8'h00}, 2);               // 'G' op=0 PMUL_G
    wait_rxn(5);                               // 'D' + status
    if (rxc[3] !== 8'h44 || rxc[4] !== 8'h00) begin
        errors = errors + 1;
        $display("FAIL pmul status: %h %h", rxc[3], rxc[4]);
    end else $display("PASS pmul done (err=0 inf=0)");

    get_q(8'h00, jx);                           // Jacobian x
    get_q(8'h01, jy);                           // Jacobian y
    get_q(8'h02, jz);                           // Jacobian z
    $display("INFO jac.x %h", jx);
    $display("INFO jac.y %h", jy);
    $display("INFO jac.z %h", jz);
    if (jz === 0) begin
        errors = errors + 1;
        $display("FAIL jac z == 0");
    end

    // ---- TB-side Jacobian -> affine:  x/z^2, y/z^3 ----------------------------
    modinv(jz, zi);
    modmul(zi, zi, z2i);
    modmul(z2i, zi, z3i);
    modmul(jx, z2i, xa);
    modmul(jy, z3i, ya);
    if (xa !== PAX) begin
        errors = errors + 1;
        $display("FAIL aff.x got %h exp %h", xa, PAX);
    end else $display("PASS aff.x (dA*G)");
    if (ya !== PAY) begin
        errors = errors + 1;
        $display("FAIL aff.y got %h exp %h", ya, PAY);
    end else $display("PASS aff.y (dA*G)");

    // ---- PMUL_G(k=1) -> affine base point via S_K1 ------------------------------
    send_blk({8'h4C, 8'h00, 248'h0, 8'h01}, 34);
    wait_rxn(rxn + 1);
    send_blk({8'h47, 8'h00}, 2);
    wait_rxn(rxn + 2);
    get_q(8'h00, xa);
    get_q(8'h01, ya);
    get_q(8'h02, jz);
    if (xa !== GX || ya !== GY || jz !== 256'd1) begin
        errors = errors + 1;
        $display("FAIL k=1: %h %h %h", xa[63:0], ya[63:0], jz);
    end else $display("PASS k=1 -> G affine (z=1)");

    // ---- PMUL_G(k=0) -> infinity -----------------------------------------------
    send_blk({8'h4C, 8'h00, 256'h0}, 34);
    wait_rxn(rxn + 1);
    base = rxn;
    send_blk({8'h47, 8'h00}, 2);
    wait_rxn(base + 2);
    if (rxc[base] !== 8'h44 || rxc[base+1][0] !== 1'b1) begin
        errors = errors + 1;
        $display("FAIL k=0 inf flag: %h %h", rxc[base], rxc[base+1]);
    end else $display("PASS k=0 -> inf");

    if (errors == 0) $display("TOP_SM2 ALL PASS");
    else             $display("TOP_SM2 ERRORS=%0d", errors);
    $finish;
end

initial begin
    #(37.0 * 40 * 1000 * 1000);
    $display("TIMEOUT rxn=%0d", rxn);
    $finish;
end

endmodule
